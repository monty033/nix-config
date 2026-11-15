#!/usr/bin/env python3
"""Mirror published .ics feeds into CalDAV calendars.

Read-only with respect to the publisher: it consumes the files the publisher
already writes and never modifies router.py or the .ics outputs.

One run reconciles N feed→collection pairs. Each pair is independent: its own
collection, its own slice of the state file, its own empty/unparseable/shrink
guards, and its own error. A broken pair does not abort the others; the run
exits non-zero and names the pair that failed.

Every DAV request path — including resource names taken from server responses —
passes through a leaf grammar bound to the pair being reconciled. The
collection name comes from configuration, never from a response, and must match
COLLECTION_RE. Siblings, other accounts, nested paths, percent-encoded
separators and dot segments are refused.

Deletes are limited to resources the mirror itself recorded for that pair, and
a feed that suddenly shrinks is refused rather than propagated. An empty or
unparseable feed is refused before any request is made for that pair.

Default is a dry run, and a dry run issues no mutating request: it does not
create the calendar.

The collection's display name is derived from the collection slug (``family`` →
``Family``). Home Assistant derives its entity id from the calendar display
name, so this is what keeps ``calendar.family`` stable across the migration.

Usage:
    caldav_mirror.py [--apply] [--verify] [--allow-shrink]
                     [--pairs FILE | --ics PATH --collection NAME] [--json]

Exit codes (the monitoring contract; one meaning each):
    0   success (dry run or applied)
    2   configuration or credentials unusable
    11  a feed is missing or unreadable
    12  a feed is not valid iCalendar
    13  refused: an empty feed, a suspicious shrink, or a path outside the
        pair's collection
    14  the collection differs from the feed (applied and still different, or
        a checking run that found drift or a stale calendar)
    16  another run held the state lock for the whole wait
    21  a DAV request failed
    31  the run succeeded but the state file could not be written
    With several pairs the code is 2 when the run stops, otherwise the highest
    code among the pairs that failed. `--spool` appends one JSON line per
    failure so a watchdog can turn it into an alert without parsing stderr.
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import copy
import datetime as dt
import fcntl
import hashlib
import http.client
import json
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

from pathlib import Path

DEFAULT_COLLECTION = "spike-family"
HERMES_HOME = Path(os.environ.get("HERMES_HOME", "/var/lib/hermes/.hermes"))
DEFAULT_ICS = HERMES_HOME / "workspace/calendars/family.ics"
CALENDARS_DIR = HERMES_HOME / "workspace/calendars"
STATE_DIR = HERMES_HOME / "workspace/calendar-mirror-state"
STATE_FILE = STATE_DIR / "state.json"
# Where the state used to live. Both are read once when the new path is still
# empty, so the deployed ownership record is not silently discarded on upgrade.
# They also sit inside the directory the path unit watches, which is exactly why
# the state moved out: a write there retriggered the unit on every run.
LEGACY_STATE_FILES = (
    CALENDARS_DIR / ".state/caldav-spike/state.json",
    CALENDARS_DIR / ".state/caldav-mirror/state.json",
)
LEGACY_STATE_FILE = LEGACY_STATE_FILES[0]
PAIRS_FILE = STATE_DIR / "pairs.json"
ENV_FILE = HERMES_HOME / ".env"
PRODID = "-//MontyCasa//CalDAV mirror (spike)//EN"
TIMEOUT = 45

# A resource leaf is a plain file name. No slashes, no percent escapes, no dot
# segments, nothing that a server could decode into a different path.
LEAF_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,120}\.ics\Z")

# A collection name is a slug. It is configuration, but it becomes a URL path
# component, so it is validated like one.
COLLECTION_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")

STATE_VERSION = 2

# How long a run waits for the state lock before giving up.
LOCK_WAIT = 120.0

# Refuse to propagate a feed that lost more than this share of its resources.
SHRINK_FLOOR = 0.6
SHRINK_MIN_PREVIOUS = 10


class GuardError(Exception):
    """A path outside the collection being reconciled was requested."""


class SourceError(Exception):
    """The source feed is missing, unreadable, unparseable, empty or refused."""


class ParseError(SourceError):
    """The feed is not valid iCalendar (code 12)."""


class RefusalError(SourceError):
    """The mirror refused to propagate this feed (code 13)."""


class EmptyFeed(RefusalError):
    """The feed parsed but carries no dated event.

    Distinct from an unreadable or unparseable feed: "nothing on the calendar"
    is a legitimate state for a person feed, so a pair may opt into skipping it
    instead of failing.
    """


class ConfigError(Exception):
    """Configuration or credentials are missing or unusable."""


class LockBusy(Exception):
    """Another run held the state lock for the whole wait (code 16)."""


class StateError(Exception):
    """The run succeeded but its state could not be recorded (code 31)."""


class DavError(Exception):
    """A DAV request failed."""


# ---------------------------------------------------------------- pure logic


def resource_name(uid: str) -> str:
    """Stable resource name for an event UID (32 hex chars + .ics)."""
    return hashlib.sha256(uid.encode("utf-8")).hexdigest()[:32] + ".ics"


def canonical(body: str) -> str:
    """Line-ending and whitespace insensitive form of a calendar body.

    Servers are allowed to re-wrap lines, change line endings and drop trailing
    spaces; none of that is drift. Blank lines carry no meaning in iCalendar.
    """
    text = body.replace("\r\n", "\n").replace("\r", "\n")
    unfolded: list[str] = []
    for line in text.split("\n"):
        if line[:1] in (" ", "\t") and unfolded:
            unfolded[-1] += line[1:]      # RFC 5545 folding: join the halves
        else:
            unfolded.append(line)
    return "\n".join(line.rstrip() for line in unfolded if line.strip())


def body_hash(body: str) -> str:
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


def display_name(collection: str) -> str:
    """Calendar display name for a collection slug.

    Home Assistant names its entity after this display name, so `family`
    must render as `Family` for the entity id to stay `calendar.family`.
    """
    return collection.replace("-", " ").title()


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
        raise ParseError("feed could not be parsed as iCalendar") from exc
    groups: dict[str, list] = {}
    for comp in cal.walk("VEVENT"):
        uid = str(comp.get("UID") or "").strip()
        if not uid:
            continue
        groups.setdefault(uid, []).append(comp)
    timezones = [copy.deepcopy(tz) for tz in cal.walk("VTIMEZONE")]
    if not groups:
        raise EmptyFeed("feed contains no VEVENT with a UID")
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

    The publisher rewrites each feed in place, so a mirror run that catches a
    partial write would otherwise delete the events missing from the partial
    file. Losing more than SHRINK_FLOOR of a non-trivial resource set is
    treated as a broken read, not as a real deletion. The comparison is always
    against this pair's own previous count, so a broken person feed cannot
    hide behind six healthy ones.
    """
    previous = len(state)
    if allow_shrink or previous < SHRINK_MIN_PREVIOUS:
        return
    if len(desired) < previous * SHRINK_FLOOR:
        raise RefusalError(
            f"feed shrank from {previous} to {len(desired)} resources; refusing"
            " (pass --allow-shrink if the drop is real)"
        )


def calendar_path(user: str, name: str = DEFAULT_COLLECTION) -> str:
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


def _checked_path(path: str, user: str, collection: str = DEFAULT_COLLECTION) -> str:
    """Refuse anything outside the pair's collection.

    Allowed: the collection itself, and one plain `.ics` leaf inside it.
    Refused: other accounts, sibling calendars, nested paths, percent-escaped
    separators and dot segments.
    """
    if not COLLECTION_RE.fullmatch(collection or ""):
        raise ConfigError(f"invalid collection name {collection!r}")
    base = calendar_path(user, collection)
    if path == base:
        return path
    if path.startswith(base):
        leaf = path[len(base):]
        if LEAF_RE.match(leaf) and ".." not in leaf:
            return path
    raise GuardError(f"refusing path outside {base!r}")


# ------------------------------------------------------------------ DAV layer


class Dav:
    """Minimal CalDAV client: only the calls this mirror needs.

    The `collection` argument is the slug of the calendar inside the account.
    It defaults to the spike collection so single-pair callers stay unchanged.
    """

    def __init__(self, base: str, user: str, password: str, timeout: int = TIMEOUT):
        self.base = base.rstrip("/")
        self.user = user
        token = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")
        self._auth = "Basic " + token
        self.timeout = timeout
        self.calls = 0

    def _call(self, method: str, path: str, body: bytes | None = None,
              ctype: str = "application/xml; charset=utf-8", depth: str = "0",
              collection: str = DEFAULT_COLLECTION) -> tuple[int, str]:
        _checked_path(path, self.user, collection)
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

    def ensure_calendar(self, collection: str = DEFAULT_COLLECTION) -> str:
        path = calendar_path(self.user, collection)
        body = (
            '<?xml version="1.0"?><c:mkcalendar xmlns:d="DAV:" '
            'xmlns:c="urn:ietf:params:xml:ns:caldav"><d:set><d:prop>'
            f"<d:displayname>{display_name(collection)}</d:displayname>"
            '<c:supported-calendar-component-set><c:comp name="VEVENT"/>'
            "</c:supported-calendar-component-set></d:prop></d:set></c:mkcalendar>"
        ).encode("utf-8")
        status, _ = self._call("MKCALENDAR", path, body, collection=collection)
        if status not in (201, 405):
            raise DavError(f"MKCALENDAR returned {status}")
        return path

    def list_resources(self, ensure: bool = True, collection: str = DEFAULT_COLLECTION) -> dict[str, str]:
        """Resource names and ETags in the collection.

        `ensure=False` performs no mutating request: a missing collection
        simply reads as empty.
        """
        path = self.ensure_calendar(collection) if ensure else calendar_path(self.user, collection)
        body = (
            '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop>'
            "<d:getetag/></d:prop></d:propfind>"
        ).encode("utf-8")
        status, text = self._call("PROPFIND", path, body, depth="1", collection=collection)
        if status == 404 and not ensure:
            return {}
        if status not in (207, 200):
            raise DavError(f"PROPFIND returned {status}")
        out: dict[str, str] = {}
        listing = calendar_path(self.user, collection).rstrip("/")
        for chunk in text.split("<d:response")[1:]:
            href = _tag(chunk, "href")
            if not href:
                continue
            # A depth-1 listing includes the collection itself. Skip exactly
            # that one; any other directory entry is unexpected, so it fails
            # closed through the same leaf grammar resource names must pass.
            if href.rstrip("/") == listing:
                continue
            out[name_from_href(href)] = _tag(chunk, "getetag") or ""
        return out

    def collection_exists(self, collection: str = DEFAULT_COLLECTION) -> bool:
        """Does the calendar itself exist, as opposed to being empty?"""
        path = calendar_path(self.user, collection)
        body = ('<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop>'
                "<d:resourcetype/></d:prop></d:propfind>").encode("utf-8")
        status, _ = self._call("PROPFIND", path, body, depth="0", collection=collection)
        if status in (207, 200):
            return True
        if status == 404:
            return False
        raise DavError(f"PROPFIND returned {status}")

    def put(self, name: str, body: str, collection: str = DEFAULT_COLLECTION) -> None:
        status, _ = self._call("PUT", calendar_path(self.user, collection) + name,
                               body.encode("utf-8"), ctype="text/calendar; charset=utf-8",
                               collection=collection)
        if status not in (201, 204):
            raise DavError(f"PUT returned {status}")

    def delete(self, name: str, collection: str = DEFAULT_COLLECTION) -> None:
        status, _ = self._call("DELETE", calendar_path(self.user, collection) + name,
                               collection=collection)
        if status not in (204, 200, 404):
            raise DavError(f"DELETE returned {status}")

    def get(self, name: str, collection: str = DEFAULT_COLLECTION) -> str | None:
        """Resource body, or None when the server does not have it."""
        status, text = self._call("GET", calendar_path(self.user, collection) + name,
                                  ctype="text/calendar; charset=utf-8",
                                  collection=collection)
        if status == 404:
            return None
        if status != 200:
            # 207 is a Multi-Status body, not the resource; hashing it would
            # report drift forever.
            raise DavError(f"GET returned {status}")
        return text


class PairDav:
    """A Dav bound to one collection, so a pair reads as the old client."""

    def __init__(self, dav: Dav, collection: str):
        self.dav = dav
        self.collection = collection

    def ensure_calendar(self) -> str:
        return self.dav.ensure_calendar(self.collection)

    def list_resources(self, ensure: bool = True) -> dict[str, str]:
        return self.dav.list_resources(ensure=ensure, collection=self.collection)

    def collection_exists(self) -> bool:
        return self.dav.collection_exists(self.collection)

    def put(self, name: str, body: str) -> None:
        self.dav.put(name, body, collection=self.collection)

    def delete(self, name: str) -> None:
        self.dav.delete(name, collection=self.collection)

    def get(self, name: str) -> str | None:
        return self.dav.get(name, collection=self.collection)


def _tag(chunk: str, tag: str) -> str:
    open_at = chunk.find(f"<d:{tag}")
    if open_at < 0:
        return ""
    start = chunk.find(">", open_at)
    end = chunk.find(f"</d:{tag}>", start)
    if start < 0 or end < 0:
        return ""
    value = chunk[start + 1:end].strip()
    # ETags arrive XML-escaped; unescape so comparisons are like-for-like.
    return (value.replace("&quot;", '"').replace("&apos;", "'")
                 .replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&"))


# ------------------------------------------------------------------- runtime


class Pair:
    """One feed mirrored into one collection."""

    __slots__ = ("feed", "collection", "enabled", "allow_empty", "create_calendar")

    def __init__(self, feed, collection: str, enabled: bool = True,
                 allow_empty: bool = False, create_calendar: bool = False) -> None:
        if not COLLECTION_RE.fullmatch(collection):
            raise ConfigError(f"invalid collection name {collection!r}")
        self.feed = Path(feed)
        self.collection = collection
        self.enabled = enabled
        self.allow_empty = allow_empty
        # Creating a calendar is an explicit act: a typo in a collection name
        # must not quietly produce a second calendar nobody reads.
        self.create_calendar = create_calendar

    def __repr__(self) -> str:  # pragma: no cover - diagnostics only
        return (f"Pair(feed={self.feed!s}, collection={self.collection!r}, "
                f"enabled={self.enabled}, allow_empty={self.allow_empty}, "
                f"create_calendar={self.create_calendar})")

    @property
    def key(self) -> str:
        """State key: pair identity, so two collections stay independent.

        The path distinguishes two feeds with the same name in different
        directories. It does not make a rename safe: a renamed feed gets a new
        slice and the old one is reconciled by no pair, so its resources stay in
        the calendar and must be deleted by hand.
        """
        return f"{self.collection}:{self.feed}"

    @property
    def label(self) -> str:
        return self.collection


def load_pairs(path: Path) -> list[Pair]:
    """Read the pair list.

    Shape: {"pairs": [{"feed": "...", "collection": "...", "enabled": true}]}
    A bare list is accepted too. Entries with `enabled: false` are returned so
    the run can report them as skipped rather than silently ignoring them.
    """
    try:
        data = json.loads(Path(path).read_text())
    except OSError as exc:
        raise ConfigError(f"cannot read {path}: {exc.__class__.__name__}") from exc
    except ValueError as exc:
        raise ConfigError(f"{path} is not valid JSON") from exc
    entries = data.get("pairs") if isinstance(data, dict) else data
    if not isinstance(entries, list) or not entries:
        raise ConfigError(f"{path} lists no pairs")
    pairs: list[Pair] = []
    for entry in entries:
        if not isinstance(entry, dict):
            raise ConfigError(f"{path} has a non-object pair entry")
        feed = str(entry.get("feed") or "").strip()
        collection = str(entry.get("collection") or "").strip()
        if not feed or not collection:
            raise ConfigError(f"{path} has a pair without feed or collection")
        pairs.append(Pair(Path(feed).expanduser(), collection,
                          bool(entry.get("enabled", True)),
                          bool(entry.get("allow_empty", False)),
                          bool(entry.get("create_calendar", False))))
    return pairs


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


@contextlib.contextmanager
def state_lock(path: Path = STATE_FILE):
    """Serialise runs on the state file.

    The path trigger and the hourly timer can fire at the same time, and two
    runs that both read the old state would each write their own version. The
    lock is blocking because a run takes seconds; systemd's start timeout is
    the outer bound.
    """
    lock_path = Path(str(path) + ".lock")
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    handle = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    deadline = time.monotonic() + LOCK_WAIT
    try:
        while True:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise LockBusy("another mirror run holds the state lock")
                time.sleep(0.2)
        yield
    finally:
        try:
            fcntl.flock(handle, fcntl.LOCK_UN)
        finally:
            os.close(handle)


def load_state(path: Path = STATE_FILE) -> dict:
    """Read the state file.

    Version 2 keys resources by pair, so two calendars may hold the same UID
    without either one's deletes touching the other. A legacy flat file (the
    spike's single-collection state) is kept aside under "legacy" and adopted
    by the one pair it can belong to; see state_for().
    """
    source = Path(path)
    adopted = False
    if not source.exists() and Path(path) == STATE_FILE:
        for candidate in LEGACY_STATE_FILES:
            if candidate.exists():
                source = candidate
                adopted = True
                break
    try:
        data = json.loads(source.read_text())
    except FileNotFoundError:
        return {"version": STATE_VERSION, "pairs": {}}
    except OSError as exc:
        # Unreadable is not empty: that would orphan every resource.
        raise ConfigError(f"state file {source} cannot be read") from exc
    except ValueError as exc:
        # A corrupt state is the ownership record: starting from empty would
        # orphan every resource and lose the shrink baseline. Fail loudly.
        raise ConfigError(f"state file {source} is not valid JSON") from exc
    if isinstance(data, dict) and data.get("version") == STATE_VERSION:
        data.setdefault("pairs", {})
        if adopted:
            # Remember where this record came from, so the run writes it to the
            # new location even when nothing else changed.
            data["_migrated"] = True
        return data
    if not isinstance(data, dict):
        # A JSON scalar or list is as unreadable as corrupt JSON: treating it as
        # empty would discard the ownership record and then overwrite it.
        raise ConfigError(f"state file {source} is not a JSON object")
    if isinstance(data, dict):
        out = {"version": STATE_VERSION, "pairs": {}, "legacy": data}
        if adopted:
            out["_migrated"] = True
        return out
    return {"version": STATE_VERSION, "pairs": {}}


def state_for(state: dict, pair: Pair, adopt_legacy: bool = True) -> dict[str, dict]:
    """The pair's slice of the state, created on first use.

    A legacy flat state belongs to the spike collection only: adopting it for
    any other collection would claim resources the mirror never wrote.
    """
    pairs = state.setdefault("pairs", {})
    if not isinstance(pairs, dict):
        raise ConfigError("state file: 'pairs' is not an object")
    if pair.key in pairs:
        return pairs[pair.key]
    # An earlier version keyed pairs by the feed's stem, not its path. Adopt
    # that slice once so upgrading does not rewrite every resource.
    old_key = f"{pair.collection}:{pair.feed.stem}"
    rivals = [k for k in pairs if k.startswith(f"{pair.collection}:")
              and k.partition(":")[2] == pair.feed.stem]
    if old_key != pair.key and len(rivals) == 1:
        pairs[pair.key] = pairs.pop(old_key)
        return pairs[pair.key]
    legacy = state.get("legacy")
    if adopt_legacy and legacy is not None and pair.collection == DEFAULT_COLLECTION:
        pairs[pair.key] = legacy
        del state["legacy"]
        return pairs[pair.key]
    pairs[pair.key] = {}
    return pairs[pair.key]


def save_state(state: dict, path: Path = STATE_FILE) -> None:
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


def run_pair(pair: Pair, apply: bool, dav, state: dict,
             allow_shrink: bool = False, verify: bool = False) -> dict:
    """Reconcile one pair. `dav` is a PairDav (or a test double with its shape)."""
    raw = read_feed(pair.feed)
    try:
        groups, timezones = group_events(raw)
    except EmptyFeed:
        if not pair.allow_empty:
            raise
        # An empty feed on a pair that allows it is a real state, and an empty
        # feed never deletes: a publisher failure must not wipe a calendar. The
        # calendar is stale all the same, so `match` says so and a checking run
        # fails on it - the operator decides, the mirror does not guess.
        pair_state = state_for(state, pair)
        return {"collection": pair.collection, "feed": str(pair.feed),
                "events": 0, "resources": 0, "remote_before": 0,
                "create": 0, "update": 0, "delete": 0,
                "applied": False, "match": not pair_state, "ok": True,
                "empty": True, "empty_stale": bool(pair_state), "unowned": 0}
    desired = build_payloads(groups, timezones)
    if not desired:
        raise RefusalError("nothing to mirror")

    pair_state = state_for(state, pair)
    check_shrink(desired, pair_state, allow_shrink)

    # A dry run must not create the calendar, so it lists without ensure. Ask
    # first whether the calendar exists at all: an empty calendar and a missing
    # one plan identically, and the cutover needs to know which it is.
    missing_calendar = False
    checker = getattr(dav, "collection_exists", None)
    if callable(checker):
        missing_calendar = not checker()
    if apply:
        if missing_calendar and not pair.create_calendar:
            raise RefusalError(
                f"calendar {pair.collection!r} does not exist; refusing to create it"
                " (set create_calendar on this pair to allow that)"
            )
        if missing_calendar:
            # Creation is the pair's explicit permission, not a side effect of
            # listing the collection.
            dav.ensure_calendar()

    remote = dav.list_resources(ensure=False)
    # Resources here and not in the slice mean the slice is gone (lost, renamed
    # or never written). The plan is still safe - it only writes, and deletes
    # come from the slice - so the run proceeds and adopts what it finds, while
    # saying so. Refusing would have been a dead end: no state would ever be
    # written and every later run would fail the same way.
    state_lost = bool(remote) and not pair_state
    actions = plan(desired, remote, pair_state)

    result = {
        "collection": pair.collection,
        "feed": str(pair.feed),
        "events": len(groups),
        "resources": len(desired),
        "remote_before": len(remote),
        "create": sum(1 for a, _ in actions if a == "put" and _ not in remote),
        "update": sum(1 for a, _ in actions if a == "put" and _ in remote),
        "delete": sum(1 for a, _ in actions if a == "delete"),
        "applied": False,
        "match": not actions,
        "ok": True,
        "create_calendar": missing_calendar,
        # Server resources the feed does not contain and this pair does not own.
        # They are reported, not deleted: a hand-added event is legitimate, and
        # a lost state file must not turn into 31 deletions.
        "unowned": len(set(remote) - set(desired) - set(pair_state)),
        # Nothing owned but the calendar is not empty: the state slice is gone
        # (lost, renamed or reset), and every resource now looks unowned.
        "state_lost": state_lost,
    }

    def read_back() -> int:
        """Resources whose content on the server differs from the payload.

        The comparison is canonical, not byte-exact: a server is allowed to
        re-wrap lines or change line endings, and a check that cannot tell that
        from real drift would alarm every day for ever.
        """
        mismatched = 0
        for name in sorted(desired):
            body = dav.get(name)
            # A resource that is not there is a pending create, which the plan
            # already reports; body drift is what a read-back can prove.
            if body is not None and canonical(body) != canonical(desired[name]):
                mismatched += 1
        return mismatched

    if verify:
        # An adoption that has not yet been confirmed by an ordinary run is
        # still unresolved drift, even though this run wrote nothing.
        result["adopted"] = bool(state.get("adoptions", {}).get(pair.key))

    if verify and not apply:
        # A checking run writes nothing, so it judges what a run would do:
        # bodies that differ (a pending update is exactly that, and the read-back
        # sees it) and deletes that are still pending because the feed dropped
        # an event. A resource that is simply absent is a pending create - the
        # ordinary gap since the last scheduled run - and is not drift.
        result["verify_mismatch"] = read_back() if hasattr(dav, "get") else 0
        result["match"] = (result["verify_mismatch"] == 0 and result["delete"] == 0
                           and not result.get("adopted"))
        return result

    if not apply:
        return result

    for action, name in actions:
        if action == "put":
            dav.put(name, desired[name])
        else:
            dav.delete(name)

    # Listing again with ensure=False: the calendar exists by now if it exists
    # at all, and a listing must never be the thing that creates it.
    fresh = dav.list_resources(ensure=False)
    new_state: dict[str, dict] = {}
    for name in desired:
        new_state[name] = {"hash": body_hash(desired[name]), "etag": fresh.get(name, "")}
    state.setdefault("pairs", {})[pair.key] = new_state
    adoptions = state.setdefault("adoptions", {})
    if not isinstance(adoptions, dict):
        raise ConfigError("state file: 'adoptions' is not an object")
    if state_lost:
        # This run adopted resources it did not own. Remember it, so a checking
        # run keeps saying so until a run finds the slice intact again.
        adoptions[pair.key] = True
    else:
        adoptions.pop(pair.key, None)
    result["applied"] = True
    result["remote_after"] = len(fresh)
    # Compare only what the mirror owns: an event added by hand in the calendar
    # is allowed to exist (it is never deleted), so it must not read as drift.
    result["match"] = set(desired) <= set(fresh)
    if verify and hasattr(dav, "get"):
        result["verify_mismatch"] = read_back()
        result["match"] = result["match"] and result["verify_mismatch"] == 0
    return result


def run(ics: Path, apply: bool, dav: Dav | None = None,
        state_file: Path = STATE_FILE, allow_shrink: bool = False,
        collection: str = DEFAULT_COLLECTION, verify: bool = False,
        create_calendar: bool = False, allow_empty: bool = False) -> dict:
    """Reconcile one feed into one collection (single-pair entry point)."""
    pair = Pair(Path(ics), collection, create_calendar=create_calendar,
                allow_empty=allow_empty)
    with state_lock(state_file):
        state = load_state(state_file)
        state.pop("_migrated", False)
        if dav is None:
            url, user, password = credentials()
            dav = Dav(url, user, password)
        result = run_pair(pair, apply, _view_for(dav, collection), state,
                          allow_shrink, verify)
        if apply:
            try:
                save_state(state, state_file)
            except (OSError, TypeError, ValueError) as exc:
                raise StateError("state file could not be written") from exc
    return result


def _view_for(dav, collection: str):
    """A client bound to one collection.

    A real Dav is wrapped; a test double may expose `for_collection()`; a
    single-pair double that has neither is used as-is.
    """
    if isinstance(dav, Dav):
        return PairDav(dav, collection)
    factory = getattr(dav, "for_collection", None)
    if callable(factory):
        return factory(collection)
    return dav


# Exit codes are the monitoring contract (calendar-caldav-migration.md D6).
# Each means one thing, so the alert text can be a fixed phrase per code.
def _code_for(exc: Exception) -> int:
    """Exit code for an exception, most specific match first.

    Walk the MRO rather than the table: a ParseError is also a SourceError, and
    the table's order would give it the parent's code.
    """
    for klass in type(exc).__mro__:
        if klass in ERROR_CODES:
            return ERROR_CODES[klass]
    return ERROR_CODES[SourceError]


ERROR_CODES = {
    ConfigError: 2,      # configuration or credentials unusable
    SourceError: 11,     # feed missing, unreadable or empty file
    ParseError: 12,      # feed is not iCalendar
    RefusalError: 13,    # mirror refused: empty feed or a suspicious shrink
    EmptyFeed: 13,
    GuardError: 13,      # a path outside the pair's collection was requested
    LockBusy: 16,        # another run held the lock for the whole wait
    StateError: 31,      # the run succeeded but its state could not be written
    DavError: 21,        # write or HTTP failure against the server
}
STATE_WRITE_FAILURE = 31
POST_WRITE_MISMATCH = 14


def run_all(pairs: list[Pair], apply: bool, dav: Dav | None = None,
            state_file: Path = STATE_FILE, allow_shrink: bool = False,
            verify: bool = False) -> tuple[list[dict], int]:
    """Reconcile every enabled pair, isolating failures.

    Returns the per-pair results and the exit code. Configuration failures
    stop the run; everything else is confined to the pair that raised it.
    """
    try:
        with state_lock(state_file):
            return _run_all_locked(pairs, apply, dav, state_file, allow_shrink, verify)
    except StateError:
        raise
    except OSError as exc:
        # The state directory is unusable: report the contract's state code
        # rather than an unhandled traceback.
        raise StateError("state file or its lock could not be opened") from exc


def _run_all_locked(pairs, apply, dav, state_file, allow_shrink, verify):
    state = load_state(state_file)
    migrated = bool(state.pop("_migrated", False))
    if dav is None:
        url, user, password = credentials()
        dav = Dav(url, user, password)

    results: list[dict] = []
    codes: list[int] = []
    dirty = False
    for pair in pairs:
        if not pair.enabled:
            results.append({"collection": pair.collection, "feed": str(pair.feed),
                            "skipped": True, "ok": True})
            continue
        try:
            result = run_pair(pair, apply, _view_for(dav, pair.collection), state,
                              allow_shrink, verify)
        except ConfigError:
            raise
        except (OSError, ValueError) as exc:
            # A path that cannot even be built (a NUL byte, for instance) is a
            # configuration failure, not a crash.
            result = {"collection": pair.collection, "feed": str(pair.feed),
                      "ok": False, "error": f"{exc.__class__.__name__}",
                      "match": False}
            codes.append(ERROR_CODES[ConfigError] if isinstance(exc, ValueError)
                         else ERROR_CODES[DavError])
        except (SourceError, DavError, GuardError) as exc:
            result = {"collection": pair.collection, "feed": str(pair.feed),
                      "ok": False, "error": f"{exc.__class__.__name__}: {exc}",
                      "match": False}
            codes.append(_code_for(exc))
        results.append(result)
        if result.get("applied") and not result.get("match"):
            codes.append(POST_WRITE_MISMATCH)
        elif verify and result.get("ok") and (not result.get("match")
                                              or result.get("state_lost")):
            # A deep check that finds drift is a failure even though it wrote
            # nothing. That includes drift the plan can only fix by writing:
            # an event the feed dropped still sits in the calendar.
            codes.append(POST_WRITE_MISMATCH)
        dirty = dirty or bool(result.get("applied"))

    if apply and any(r.get("empty") for r in results):
        # An empty pair is a completed run: touch the state so the freshness
        # check does not report a healthy mirror as stale.
        dirty = True
    if verify and any(r.get("empty_stale") for r in results):
        # An empty feed over a calendar that still holds events is drift, and a
        # check must fail on it. An applied run only reports it: it deliberately
        # deletes nothing there, so failing would alert hourly for ever.
        codes.append(POST_WRITE_MISMATCH)
    if dirty or migrated:
        try:
            save_state(state, state_file)
        except (OSError, TypeError, ValueError) as exc:
            # The run succeeded but cannot record what it did; the next run
            # would rewrite everything. Reported, not swallowed.
            print(f"mirror: state: {exc.__class__.__name__}", file=sys.stderr)
            codes.append(STATE_WRITE_FAILURE)
    return results, (max(codes) if codes else 0)


def render(results: list[dict], apply: bool) -> str:
    """One line per pair, prefixed with the run mode."""
    parts = []
    for result in results:
        label = result.get("collection", "?")
        if result.get("skipped"):
            parts.append(f"{label} skipped")
        elif result.get("empty"):
            tail = " stale" if result.get("empty_stale") else ""
            parts.append(f"{label} empty (no events){tail}")
        elif not result.get("ok", True):
            parts.append(f"{label} FAILED {result.get('error', '')}")
        else:
            match = "yes" if result["match"] else "no"
            extra = " +calendar" if result.get("create_calendar") else ""
            if "verify_mismatch" in result:
                extra += f" verify={result['verify_mismatch']}"
            if result.get("unowned"):
                extra += f" unowned={result['unowned']}"
            if result.get("state_lost"):
                extra += " state-lost"
            parts.append(
                f"{label} +{result['create']} ~{result['update']} -{result['delete']} "
                f"={result['resources']} match={match}{extra}"
            )
    mode = "applied" if apply else "dry-run"
    return f"caldav[{mode}] " + " | ".join(parts)


def spool_record(path: Path, code: int, results: list[dict] | None) -> None:
    """Append one machine-readable failure line, and nothing on success.

    Counts only: no feed paths, no collection names, no credentials, no UIDs.
    The watchdog reads these, so the format is the contract.
    """
    if code == 0:
        return
    rows = results or []
    record = {
        "at": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat(),
        "unit": "calendar-caldav-mirror",
        "source": "mirror",
        "code": code,
        "pairs": len(rows),
        "failed": (sum(1 for r in rows if not r.get("ok", True)) if rows else 1),
        "empty": sum(1 for r in rows if r.get("empty")),
        "unowned": sum(int(r.get("unowned") or 0) for r in rows),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_CREAT | os.O_WRONLY | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a") as handle:
        handle.write(json.dumps(record, sort_keys=True) + "\n")


def _pairs_from_args(args) -> list[Pair]:
    """Either the pair list, or the single feed the flags describe.

    An explicit --ics (or a single-pair-only flag) means the caller wants one
    feed; otherwise the service's pair list is the default, so a bare run and
    the systemd unit do the same thing.
    """
    single = bool(args.ics) or bool(getattr(args, "create_calendar", False)
                                    or getattr(args, "allow_empty", False))
    if args.pairs:
        return load_pairs(Path(args.pairs))
    if single:
        return [Pair(Path(args.ics or DEFAULT_ICS), args.collection,
                     allow_empty=getattr(args, "allow_empty", False),
                     create_calendar=getattr(args, "create_calendar", False))]
    if Path(PAIRS_FILE).exists():
        return load_pairs(PAIRS_FILE)
    return [Pair(Path(DEFAULT_ICS), args.collection)]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Mirror .ics feeds into CalDAV calendars")
    parser.add_argument("--apply", action="store_true", help="write (default is a dry run)")
    parser.add_argument("--verify", action="store_true",
                        help="also read every resource back and compare its body")
    parser.add_argument("--allow-shrink", action="store_true",
                        help="permit a feed that lost most of its resources")
    parser.add_argument("--create-calendar", action="store_true",
                        help="allow the single-pair path to create its collection")
    parser.add_argument("--allow-empty", action="store_true",
                        help="accept a feed that is legitimately empty")
    parser.add_argument("--pairs",
                        help="JSON file listing feed→collection pairs "
                             "(default: the service's list, or a single --ics)")
    parser.add_argument("--ics", help="single source feed (with --collection)")
    parser.add_argument("--collection", default=DEFAULT_COLLECTION,
                        help="single destination collection")
    parser.add_argument("--state", default=str(STATE_FILE), help="state file")
    parser.add_argument("--spool", help="append one JSON line here on failure")
    parser.add_argument("--json", action="store_true", help="machine-readable summary")
    args = parser.parse_args(argv)

    spool = Path(args.spool) if args.spool else None
    results: list[dict] = []
    code = 0
    try:
        pairs = _pairs_from_args(args)
        results, code = run_all(pairs, args.apply, state_file=Path(args.state),
                                allow_shrink=args.allow_shrink, verify=args.verify)
    except ConfigError as exc:
        print(f"mirror: config: {exc}", file=sys.stderr)
        code = 2
    except GuardError as exc:
        print(f"mirror: guard: {exc}", file=sys.stderr)
        code = ERROR_CODES[GuardError]
    except ParseError as exc:
        print(f"mirror: parse: {exc}", file=sys.stderr)
        code = ERROR_CODES[ParseError]
    except RefusalError as exc:
        print(f"mirror: refused: {exc}", file=sys.stderr)
        code = ERROR_CODES[RefusalError]
    except SourceError as exc:
        print(f"mirror: source: {exc}", file=sys.stderr)
        code = ERROR_CODES[SourceError]
    except LockBusy as exc:
        print(f"mirror: busy: {exc}", file=sys.stderr)
        code = ERROR_CODES[LockBusy]
    except StateError as exc:
        print(f"mirror: state: {exc}", file=sys.stderr)
        code = ERROR_CODES[StateError]
    except DavError as exc:
        print(f"mirror: dav: {exc}", file=sys.stderr)
        code = ERROR_CODES[DavError]
    except ValueError as exc:
        print(f"mirror: configuration: {exc.__class__.__name__}", file=sys.stderr)
        code = ERROR_CODES[ConfigError]

    if args.json:
        print(json.dumps({"apply": args.apply, "pairs": results}, sort_keys=True))
    else:
        print(render(results, args.apply))

    if code:
        if spool is not None:
            try:
                spool_record(spool, code, results)
            except OSError:
                print("mirror: cannot write the failure spool", file=sys.stderr)
        return code

    return code


if __name__ == "__main__":
    sys.exit(main())
