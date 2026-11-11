#!/usr/bin/env python3
"""Mirror the published family.ics into a CalDAV calendar (spike).

Read-only with respect to the publisher: it consumes the file the publisher
already writes and never modifies router.py or the .ics outputs.

Writes are confined to one collection, named CALENDAR_NAME, under the
configured CalDAV account. Every DAV request path — including resource names
taken from server responses — passes through _checked_path(), which accepts
the collection itself or a plain `.ics` leaf and refuses everything else
(siblings, other accounts, nested paths, percent-encoded separators, dot
segments).

Deletes are limited to resources the mirror itself recorded in its state file,
and a feed that suddenly shrinks is refused rather than propagated. An empty
or unparseable feed is refused before any request is made.

Default is a dry run, and a dry run issues no mutating request: it does not
create the calendar.

Usage:
    caldav_mirror.py [--apply] [--allow-shrink] [--ics PATH] [--json]

Exit codes:
    0  success (dry run or applied)
    2  configuration/credential problem
    3  source problem: missing, unreadable, unparseable, empty, or refused
       because the feed shrank
    4  DAV request failed
    5  path guard tripped
"""

from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import http.client
import json
import os
import re
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

CALENDAR_NAME = "spike-family"
HERMES_HOME = Path(os.environ.get("HERMES_HOME", "/var/lib/hermes/.hermes"))
DEFAULT_ICS = HERMES_HOME / "workspace/calendars/family.ics"
STATE_DIR = HERMES_HOME / "workspace/calendars/.state/caldav-spike"
STATE_FILE = STATE_DIR / "state.json"
ENV_FILE = HERMES_HOME / ".env"
PRODID = "-//MontyCasa//CalDAV mirror (spike)//EN"
TIMEOUT = 45

# A resource leaf is a plain file name. No slashes, no percent escapes, no dot
# segments, nothing that a server could decode into a different path.
LEAF_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,120}\.ics$")

# Refuse to propagate a feed that lost more than this share of its resources.
SHRINK_FLOOR = 0.6
SHRINK_MIN_PREVIOUS = 10


class GuardError(Exception):
    """A path outside the one allowed collection was requested."""


class SourceError(Exception):
    """The source feed is missing, unreadable, unparseable, empty or refused."""


class ConfigError(Exception):
    """Configuration or credentials are missing or unusable."""


class DavError(Exception):
    """A DAV request failed."""


# ---------------------------------------------------------------- pure logic


def resource_name(uid: str) -> str:
    """Stable resource name for an event UID (32 hex chars + .ics)."""
    return hashlib.sha256(uid.encode("utf-8")).hexdigest()[:32] + ".ics"


def body_hash(body: str) -> str:
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


def read_feed(path: Path) -> bytes:
    try:
        raw = Path(path).read_bytes()
    except OSError as exc:
        raise SourceError(f"cannot read {path}: {exc.__class__.__name__}") from exc
    if not raw.strip():
        raise SourceError(f"{path} is empty")
    return raw


def group_events(raw: bytes) -> tuple[dict[str, list], list]:
    """Group VEVENTs by UID and collect the VTIMEZONEs the feed defines.

    A master event and its RECURRENCE-ID overrides share one UID and must
    travel in one resource, which is what CalDAV expects.
    """
    import icalendar

    try:
        cal = icalendar.Calendar.from_ical(raw)  # type: ignore[arg-type]  # bytes are accepted at runtime
    except ValueError as exc:
        raise SourceError("feed could not be parsed as iCalendar") from exc
    groups: dict[str, list] = {}
    for comp in cal.walk("VEVENT"):
        uid = str(comp.get("UID") or "").strip()
        if not uid:
            continue
        groups.setdefault(uid, []).append(comp)
    timezones = [copy.deepcopy(tz) for tz in cal.walk("VTIMEZONE")]
    if not groups:
        raise SourceError("feed contains no VEVENT with a UID")
    return groups, timezones


def build_payloads(groups: dict[str, list], timezones: list) -> dict[str, str]:
    """One VCALENDAR per UID, carrying the feed's VTIMEZONEs."""
    import icalendar

    payloads: dict[str, str] = {}
    for uid, comps in groups.items():
        cal = icalendar.Calendar()
        cal.add("prodid", PRODID)
        cal.add("version", "2.0")
        for tz in timezones:
            cal.add_component(copy.deepcopy(tz))
        for comp in comps:
            cal.add_component(copy.deepcopy(comp))
        payloads[resource_name(uid)] = cal.to_ical().decode("utf-8")
    return payloads


def plan(desired: dict[str, str], remote_etags: dict[str, str],
         state: dict[str, dict]) -> list[tuple[str, str]]:
    """Actions needed to make the collection match the feed.

    ("put", name) uploads a new resource, or repairs one that is missing,
    whose body no longer matches the feed, or whose server ETag changed under
    us (someone edited it outside the mirror).

    ("delete", name) removes a resource that the mirror created and that no
    longer exists upstream. Only names recorded in the state file are ever
    deleted, so an event added by hand in the Nextcloud UI survives.
    """
    actions: list[tuple[str, str]] = []
    for name in sorted(desired):
        want = body_hash(desired[name])
        seen = state.get(name)
        if name not in remote_etags:
            actions.append(("put", name))
        elif seen is None:
            actions.append(("put", name))
        elif seen.get("hash") != want:
            actions.append(("put", name))
        elif seen.get("etag") and seen.get("etag") != remote_etags[name]:
            actions.append(("put", name))
    owned = set(state) & set(remote_etags)
    for name in sorted(owned - set(desired)):
        actions.append(("delete", name))
    return actions


def check_shrink(desired: dict[str, str], state: dict[str, dict],
                 allow_shrink: bool = False) -> None:
    """Refuse a feed that lost most of its resources, before any request.

    The publisher rewrites the feed in place, so a mirror run that catches a
    partial write would otherwise delete the events missing from the partial
    file. Losing more than SHRINK_FLOOR of a non-trivial resource set is
    treated as a broken read, not as a real deletion.
    """
    previous = len(state)
    if allow_shrink or previous < SHRINK_MIN_PREVIOUS:
        return
    if len(desired) < previous * SHRINK_FLOOR:
        raise SourceError(
            f"feed shrank from {previous} to {len(desired)} resources; refusing"
            " (pass --allow-shrink if the drop is real)"
        )


def calendar_path(user: str, name: str = CALENDAR_NAME) -> str:
    return f"/remote.php/dav/calendars/{user}/{name}/"


def name_from_href(href: str) -> str:
    """Turn a PROPFIND href into a validated resource leaf.

    The href is server-controlled, so it is percent-decoded first and then
    checked against the same leaf grammar the guard uses. Anything that does
    not decode to one plain file name is refused rather than repaired.
    """
    if not href:
        raise GuardError("empty href in server response")
    leaf = urllib.parse.unquote(href.rstrip("/").rsplit("/", 1)[-1])
    if not LEAF_RE.match(leaf):
        raise GuardError("server returned a resource name outside the collection")
    return leaf


def _checked_path(path: str, user: str) -> str:
    """Refuse anything outside the one spike collection.

    Allowed: the collection itself, and one plain `.ics` leaf inside it.
    Refused: other accounts, sibling calendars, nested paths, percent-escaped
    separators and dot segments.
    """
    base = calendar_path(user)
    if path == base:
        return path
    if path.startswith(base):
        leaf = path[len(base):]
        if LEAF_RE.match(leaf) and ".." not in leaf:
            return path
    raise GuardError(f"refusing path outside {base!r}")


# ------------------------------------------------------------------ DAV layer


class Dav:
    """Minimal CalDAV client: only the calls this mirror needs."""

    def __init__(self, base: str, user: str, password: str, timeout: int = TIMEOUT):
        self.base = base.rstrip("/")
        self.user = user
        token = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")
        self._auth = "Basic " + token
        self.timeout = timeout
        self.calls = 0

    def _call(self, method: str, path: str, body: bytes | None = None,
              ctype: str = "application/xml; charset=utf-8", depth: str = "0") -> tuple[int, str]:
        _checked_path(path, self.user)
        headers = {"Authorization": self._auth, "Depth": depth, "Content-Type": ctype}
        try:
            req = urllib.request.Request(self.base + path, data=body, method=method, headers=headers)
        except (ValueError, http.client.InvalidURL) as exc:
            # Never let the URL, which may carry userinfo, reach the message.
            raise DavError(f"{method} failed: invalid request URL") from exc
        self.calls += 1
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return resp.status, resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as exc:
            return exc.code, ""
        except (urllib.error.URLError, http.client.HTTPException, TimeoutError, ValueError) as exc:
            raise DavError(f"{method} failed: {exc.__class__.__name__}") from exc

    def ensure_calendar(self) -> str:
        path = calendar_path(self.user)
        display = CALENDAR_NAME.replace("-", " ").title()
        body = (
            '<?xml version="1.0"?><c:mkcalendar xmlns:d="DAV:" '
            'xmlns:c="urn:ietf:params:xml:ns:caldav"><d:set><d:prop>'
            f"<d:displayname>{display}</d:displayname>"
            '<c:supported-calendar-component-set><c:comp name="VEVENT"/>'
            "</c:supported-calendar-component-set></d:prop></d:set></c:mkcalendar>"
        ).encode("utf-8")
        status, _ = self._call("MKCALENDAR", path, body)
        if status not in (201, 405):
            raise DavError(f"MKCALENDAR returned {status}")
        return path

    def list_resources(self, ensure: bool = True) -> dict[str, str]:
        """Resource names and ETags in the collection.

        `ensure=False` performs no mutating request: a missing collection
        simply reads as empty.
        """
        path = self.ensure_calendar() if ensure else calendar_path(self.user)
        body = (
            '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop>'
            "<d:getetag/></d:prop></d:propfind>"
        ).encode("utf-8")
        status, text = self._call("PROPFIND", path, body, depth="1")
        if status == 404 and not ensure:
            return {}
        if status not in (207, 200):
            raise DavError(f"PROPFIND returned {status}")
        out: dict[str, str] = {}
        collection = calendar_path(self.user).rstrip("/")
        for chunk in text.split("<d:response")[1:]:
            href = _tag(chunk, "href")
            if not href:
                continue
            # A depth-1 listing includes the collection itself. Skip exactly
            # that one; any other directory entry is unexpected, so it fails
            # closed through the same leaf grammar resource names must pass.
            if href.rstrip("/") == collection:
                continue
            out[name_from_href(href)] = _tag(chunk, "getetag") or ""
        return out

    def put(self, name: str, body: str) -> None:
        status, _ = self._call("PUT", calendar_path(self.user) + name,
                               body.encode("utf-8"), ctype="text/calendar; charset=utf-8")
        if status not in (201, 204):
            raise DavError(f"PUT returned {status}")

    def delete(self, name: str) -> None:
        status, _ = self._call("DELETE", calendar_path(self.user) + name)
        if status not in (204, 200, 404):
            raise DavError(f"DELETE returned {status}")


def _tag(chunk: str, tag: str) -> str:
    open_at = chunk.find(f"<d:{tag}")
    if open_at < 0:
        return ""
    start = chunk.find(">", open_at)
    end = chunk.find(f"</d:{tag}>", start)
    if start < 0 or end < 0:
        return ""
    return chunk[start + 1:end].strip()


# ------------------------------------------------------------------- runtime


def credentials(env: dict | None = None, env_file: Path = ENV_FILE,
                use_process_env: bool = True) -> tuple[str, str, str]:
    """Resolve CalDAV credentials.

    Precedence: explicit `env` argument, then the process environment, then
    the env file. Tests pass `use_process_env=False` so a live credential in
    the caller's environment can never satisfy an assertion.
    """
    values = dict(os.environ) if use_process_env else {}
    if env_file.exists():
        try:
            for line in env_file.read_text(errors="replace").splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                values.setdefault(key.strip(), val.strip().strip('"').strip("'"))
        except OSError as exc:
            raise ConfigError(f"cannot read {env_file}: {exc.__class__.__name__}") from exc
    if env:
        values.update(env)
    url = values.get("NEXTCLOUD_URL", "").strip()
    user = values.get("NEXTCLOUD_USERNAME", "").strip()
    password = values.get("NEXTCLOUD_PASSWORD", "").strip()
    if not (url and user and password):
        raise ConfigError("NEXTCLOUD_URL, NEXTCLOUD_USERNAME and NEXTCLOUD_PASSWORD are required")
    return url, user, password


def load_state(path: Path = STATE_FILE) -> dict[str, dict]:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def save_state(state: dict[str, dict], path: Path = STATE_FILE) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".state-")
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(state, handle, indent=2, sort_keys=True)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def run(ics: Path, apply: bool, dav: Dav | None = None,
        state_file: Path = STATE_FILE, allow_shrink: bool = False) -> dict:
    raw = read_feed(ics)
    groups, timezones = group_events(raw)
    desired = build_payloads(groups, timezones)
    if not desired:
        raise SourceError("nothing to mirror")

    state = load_state(state_file)
    check_shrink(desired, state, allow_shrink)

    if dav is None:
        url, user, password = credentials()
        dav = Dav(url, user, password)

    # A dry run must not create the calendar, so it lists without ensure.
    remote = dav.list_resources(ensure=apply)
    actions = plan(desired, remote, state)

    result = {
        "events": len(groups),
        "resources": len(desired),
        "remote_before": len(remote),
        "create": sum(1 for a, _ in actions if a == "put" and _ not in remote),
        "update": sum(1 for a, _ in actions if a == "put" and _ in remote),
        "delete": sum(1 for a, _ in actions if a == "delete"),
        "applied": False,
        "match": not actions,
    }
    if not apply:
        return result

    for action, name in actions:
        if action == "put":
            dav.put(name, desired[name])
        else:
            dav.delete(name)

    fresh = dav.list_resources()
    new_state = {}
    for name in desired:
        new_state[name] = {"hash": body_hash(desired[name]), "etag": fresh.get(name, "")}
    save_state(new_state, state_file)
    result["applied"] = True
    result["remote_after"] = len(fresh)
    result["match"] = set(fresh) == set(desired)
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Mirror family.ics into CalDAV")
    parser.add_argument("--apply", action="store_true", help="write (default is a dry run)")
    parser.add_argument("--allow-shrink", action="store_true",
                        help="permit a feed that lost most of its resources")
    parser.add_argument("--ics", default=str(DEFAULT_ICS), help="source feed")
    parser.add_argument("--json", action="store_true", help="machine-readable summary")
    args = parser.parse_args(argv)

    try:
        result = run(Path(args.ics), args.apply, allow_shrink=args.allow_shrink)
    except GuardError as exc:
        print(f"mirror: guard: {exc}", file=sys.stderr)
        return 5
    except ConfigError as exc:
        print(f"mirror: config: {exc}", file=sys.stderr)
        return 2
    except SourceError as exc:
        print(f"mirror: source: {exc}", file=sys.stderr)
        return 3
    except DavError as exc:
        print(f"mirror: dav: {exc}", file=sys.stderr)
        return 4

    if args.json:
        print(json.dumps(result, sort_keys=True))
    else:
        mode = "applied" if result["applied"] else "dry-run"
        print(
            f"mirror[{mode}] events={result['events']} resources={result['resources']} "
            f"create={result['create']} update={result['update']} delete={result['delete']} "
            f"match={'yes' if result['match'] else 'no'}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
