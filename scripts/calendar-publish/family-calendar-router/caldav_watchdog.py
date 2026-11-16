#!/usr/bin/env python3
"""Watchdog for the CalDAV calendar mirror.

Prints nothing when everything is fine, and one line per problem when it is
not. It is meant to run from a Hermes cron job and deliver straight to
Telegram, so silence is the normal case and the output is the alert.

What it checks:

1. **Failure spool** — the mirror appends one JSON line per failed run. Each
   line is turned into a fixed phrase from the code, never from stderr.
2. **Freshness** — the mirror's state must be at least as new as the newest
   published feed, within a grace window; and the publisher must not have gone
   quiet, judged by feed age rather than by the mirror's state, which only
   moves when a run changes something.
3. **Deep verify, once a day** — a full read-back comparison catches drift the
   checksum in the state file cannot see.

Text rules: no URLs, no credentials, no event titles, no person calendar
names, no UIDs. Codes, counts and ages only.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import subprocess
import sys
from pathlib import Path

HERMES_HOME = Path(os.environ.get("HERMES_HOME", "/var/lib/hermes/.hermes"))
# Outside CALENDARS, which is the directory the path unit watches.
STATE_DIR = HERMES_HOME / "workspace/calendar-mirror-state"
CALENDARS = HERMES_HOME / "workspace/calendars"
DEFAULT_SPOOL = STATE_DIR / "failures.jsonl"
DEFAULT_STATE = STATE_DIR / "state.json"
DEFAULT_CURSOR = STATE_DIR / "watchdog.json"
DEFAULT_VERIFY = "caldav-family-mirror"  # resolved through PATH by the wrapper
# The same pair list the service mirrors, so the daily check covers every pair.
DEFAULT_PAIRS = HERMES_HOME / "workspace/calendar-mirror-state/pairs.json"

# Grace window between a feed being published and the mirror having caught up.
BEHIND_GRACE = dt.timedelta(minutes=20)
# The publisher runs hourly and writes a heartbeat on every completed run, so
# two and a half hours of silence means two missed runs, not a quiet afternoon.
FEED_MAX_AGE = dt.timedelta(hours=2.5)
DEFAULT_PUBLISH_STATE = HERMES_HOME / "workspace/calendar-publish-state/heartbeat.json"

# A canary is one event, created by hand, that must survive the whole path.
CANARY_TTL = dt.timedelta(hours=20)   # check at most once a day

PHRASES = {
    1: "the mirror crashed before it could report a reason",
    2: "configuration problem (credentials or pair list)",
    11: "a feed could not be read",
    12: "a feed is not valid iCalendar",
    13: "refused a feed (empty, or it suddenly lost most of its events) - screens are showing older data",
    14: "the calendar still differs from the feed",
    16: "another mirror run was still holding the state lock",
    21: "could not write to Nextcloud",
    31: "could not record its own state; the next run will rewrite everything",
}


def contains_summary(ics_text: str, summary: str) -> bool:
    """True when one VEVENT in the text carries exactly this summary.

    Compared on the unfolded SUMMARY line: a canary must not match a longer
    title that merely starts the same way.
    """
    if not ics_text or not summary:
        return False
    unfolded = ics_text.replace("\r\n ", "").replace("\n ", "")
    for line in unfolded.splitlines():
        line = line.strip()
        if line.startswith("SUMMARY:") and line[8:].strip() == summary:
            return True
    return False


def phrase(code: int) -> str:
    return PHRASES.get(code, f"failed with code {code}")


def load_cursor(path: Path) -> dict:
    try:
        data = json.loads(path.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_cursor(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True))
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def spool_identity(path: Path) -> str:
    """Device and inode, so a rotated spool is not mistaken for the old one."""
    try:
        info = path.stat()
    except OSError:
        return ""
    return f"{info.st_dev}:{info.st_ino}"


def new_spool_lines(path: Path, cursor: dict) -> tuple[list[dict], int, str]:
    """Failure records written since the last check.

    Rotation is detected by inode, and a shortened file by offset. A file that
    is truncated in place and then regrown past the old offset is
    indistinguishable from an unchanged one here; the mirror never truncates
    the spool, so only an operator could cause that.
    """
    try:
        size = path.stat().st_size
    except OSError:
        return [], 0, ""
    identity = spool_identity(path)
    offset = int(cursor.get("spool_offset", 0))
    if size < offset or identity != cursor.get("spool_inode"):
        offset = 0
    records: list[dict] = []
    with path.open("rb") as handle:
        handle.seek(offset)
        for raw in handle.read().splitlines():
            try:
                record = json.loads(raw)
            except ValueError:
                continue
            if isinstance(record, dict):
                records.append(record)
    return records, size, identity


def newest_feed(calendars: Path) -> dt.datetime | None:
    """The most recently modified feed, ignoring any that vanish mid-listing."""
    times = []
    for path in calendars.glob("*.ics"):
        try:
            if path.is_file():
                times.append(path.stat().st_mtime)
        except OSError:
            continue  # replaced or removed between the glob and the stat
    if not times:
        return None
    return dt.datetime.fromtimestamp(max(times), dt.timezone.utc)


def heartbeat_stamp(path: Path) -> dt.datetime | None:
    """When the publisher last finished a run, or None if it cannot be read.

    A timestamp without a timezone is treated as unreadable rather than guessed
    at: a wrong guess would either hide a dead publisher or invent one.
    """
    try:
        payload = json.loads(path.read_text())
        stamp = dt.datetime.fromisoformat(payload["last_success"])
    except (OSError, ValueError, KeyError, TypeError):
        return None
    return stamp if stamp.tzinfo is not None else None


SOURCE_LABELS = {"proton": "Proton", "google": "Google", "school": "the school feed"}


def fetch_failure(publish_state: Path) -> tuple[dt.datetime, str, str] | None:
    """The publisher's own account of the run that died, if it left one.

    It sits beside the heartbeat, which is passed in as a file path.
    """
    try:
        payload = json.loads((publish_state.parent / "last-failure.json").read_text())
        stamp = dt.datetime.fromisoformat(payload["at"])
        source = str(payload["source"])
        detail = str(payload["detail"])
    except (OSError, ValueError, KeyError, TypeError):
        return None
    return (stamp, source, detail) if stamp.tzinfo is not None else None


def failure_line(publish_state: Path, since: dt.datetime, now: dt.datetime) -> str | None:
    """Name the cause when the failing run recorded one.

    A rate limit, a bad credential and a crash all look identical from the
    outside: no heartbeat. The publisher writes down why it stopped, so the
    alert can say "HTTP 429" instead of leaving Patrick to go and look.
    """
    failure = fetch_failure(publish_state)
    if failure is None or failure[0] < since:
        return None
    # A run that died without recording anything after a recorded failure will
    # still show the older cause. Blunter than a guess, but never silent.
    _, source, detail = failure
    label = SOURCE_LABELS.get(source, source)
    hours = max(0, int((now - since).total_seconds() // 3600))
    return f"calendar publisher: {label} fetch failing ({detail}) — no successful publish for {hours} h"


def publisher_alerts(newest: dt.datetime | None, publish_state: Path,
                     now: dt.datetime, feed_max: dt.timedelta) -> list[str]:
    """Is the publisher still publishing, and if not, why?

    The heartbeat is the signal, not feed age: since an unchanged publish no
    longer rewrites anything, a quiet feed file can mean a healthy publisher
    with nothing to say. Feed age is only a fallback for a host whose publisher
    predates the heartbeat. One line, so a dead publisher cannot alert twice.
    """
    stamp = heartbeat_stamp(publish_state)
    if stamp is not None and now - stamp < dt.timedelta(minutes=-5):
        # More than five minutes in the future is clock skew, not liveness, so
        # it is not trusted either way; fall through to the fallback.
        stamp = None
    if stamp is not None:
        age = now - stamp
        if age <= feed_max:
            return []
        return [failure_line(publish_state, stamp, now)
                or f"calendar publisher: no successful publish for "
                   f"{max(0, int(age.total_seconds() // 3600))} h"]

    # No heartbeat to read: fall back to the newest feed, which the old build
    # rewrote on every run.
    if newest is None:
        # Nothing to measure a failure against, so the generic line stands.
        return ["calendar publisher: there are no feed files to publish from"]
    if now - newest <= feed_max:
        return []
    generic = (f"calendar publisher: the feeds are "
               f"{int((now - newest).total_seconds() // 3600)} h old"
               " and there is no readable heartbeat")
    return [failure_line(publish_state, newest, now) or generic]


DUPLICATE_WINDOW = 90  # seconds


def summarize_failures(records: list[dict]) -> list[str]:
    """One alert line per distinct code, with a count.

    One real failure can leave two records: the mirror writes its own line
    before exiting, and the unit's OnFailure hook writes another. Records with
    the same code inside DUPLICATE_WINDOW are one failure, not two.
    """
    order: list[int] = []
    counts: dict[int, int] = {}
    last_seen: dict[int, dt.datetime] = {}
    last_kind: dict[int, str] = {}
    previous: tuple[str, int, dt.datetime] | None = None
    for record in records:
        unit = str(record.get("unit") or "").removesuffix(".service")
        if unit not in ("", "calendar-caldav-mirror"):
            continue
        code = record.get("code")
        if not isinstance(code, int):
            continue
        stamp = _stamp(record.get("at"))
        # Only the hook's record duplicates the mirror's own: they carry the
        # same code seconds apart. Two genuine failures of one kind, both
        # written by the mirror, are two lines.
        kind = str(record.get("source") or "")
        # The unit hook cannot see the mirror's exit status, so it always writes
        # code 1 ("crashed"). When the mirror wrote its own record for the same
        # failure, the hook's line is a duplicate claim, not a second failure.
        if (kind == "hook" and previous is not None and stamp is not None
                and previous[0] == "mirror" and previous[1] == code
                and (stamp - previous[2]).total_seconds() <= DUPLICATE_WINDOW):
            # The hook's record stands in for the mirror's own line about the
            # same exit - same code, seconds apart. A different code is a
            # different failure, and a crash after an ordinary failure must
            # still be reported as a crash.
            continue
        if code not in counts:
            counts[code] = 0
            order.append(code)
        counts[code] += 1
        if stamp is not None:
            last_seen[code] = stamp
            previous = (kind, code, stamp)
    return [f"calendar mirror: {phrase(code)} ({counts[code]}x)" if counts[code] > 1
            else f"calendar mirror: {phrase(code)}"
            for code in order]


def _stamp(value: object) -> dt.datetime | None:
    if not isinstance(value, str):
        return None
    try:
        stamp = dt.datetime.fromisoformat(value)
    except ValueError:
        return None
    # A record without an offset cannot be subtracted from one with an offset.
    return stamp if stamp.tzinfo else stamp.replace(tzinfo=dt.timezone.utc)


def check_canary(summary: str, collection: str) -> bool | None:
    """Is the canary present in the collection?

    None means the check could not be made (no credentials, server
    unreachable); that is reported, never hidden, but it is not the same as a
    missing canary.
    """
    try:
        import caldav_mirror as mirror  # same directory as this script
    except ImportError:
        return None
    if not mirror.COLLECTION_RE.fullmatch(collection or ""):
        return None
    try:
        url, user, password = mirror.credentials()
        dav = mirror.Dav(url, user, password)
        remote = dav.list_resources(ensure=False, collection=collection)
        for name in sorted(remote):
            body = dav.get(name, collection=collection)
            if body and contains_summary(body, summary):
                return True
        return False
    except Exception:  # noqa: BLE001 - a watchdog never raises
        return None


def run_verify(command: str, extra: list[str] | None = None, timeout: int = 300) -> int:
    """Deep read-back through the mirror in checking mode (it writes nothing)."""
    argv = [command, "--verify", *(extra or [])]
    try:
        completed = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return int(completed.returncode)
    except (OSError, subprocess.SubprocessError):
        return 127


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Calendar mirror watchdog")
    parser.add_argument("--spool", default=str(DEFAULT_SPOOL))
    parser.add_argument("--state", default=str(DEFAULT_STATE))
    parser.add_argument("--calendars", default=str(CALENDARS))
    parser.add_argument("--cursor", default=str(DEFAULT_CURSOR))
    parser.add_argument("--verify", default=DEFAULT_VERIFY,
                        help="mirror command used for the daily deep check")
    parser.add_argument("--no-verify", action="store_true")
    parser.add_argument("--pairs", default=str(DEFAULT_PAIRS),
                        help="pair list handed to the deep check")
    parser.add_argument("--state-arg", dest="state_arg",
                        help="state file handed to the deep check (defaults to --state)")
    parser.add_argument("--spool-max-bytes", type=int, default=262144,
                        help="rotate the failure spool above this size")
    parser.add_argument("--canary-summary",
                        help="summary of one event that must survive the path")
    parser.add_argument("--canary-collection", default="family")
    parser.add_argument("--publish-state", default=str(DEFAULT_PUBLISH_STATE),
                        help="the publisher's heartbeat file")
    parser.add_argument("--feed-max-hours", type=float, default=FEED_MAX_AGE.total_seconds() / 3600,
                        help="how old the newest feed may be before the publisher is called dead")
    parser.add_argument("--now", help="override the clock (tests)")
    args = parser.parse_args(argv)

    spool = Path(args.spool)
    state = Path(args.state)
    cursor_path = Path(args.cursor)
    if args.now:
        now = dt.datetime.fromisoformat(args.now)
        if now.tzinfo is None:
            now = now.replace(tzinfo=dt.timezone.utc)
    else:
        now = dt.datetime.now(dt.timezone.utc)

    cursor = load_cursor(cursor_path)
    alerts: list[str] = []

    records, size, identity = new_spool_lines(spool, cursor)
    alerts.extend(summarize_failures(records))
    cursor["spool_offset"] = size
    cursor["spool_inode"] = identity

    # Freshness. The publisher check runs whether or not the mirror has a state
    # file: a missing state is one problem and a dead publisher is another.
    newest = newest_feed(Path(args.calendars))
    try:
        state_mtime = dt.datetime.fromtimestamp(state.stat().st_mtime, dt.timezone.utc)
        if newest is not None and newest - state_mtime > BEHIND_GRACE:
            behind = int((newest - state_mtime).total_seconds() // 60)
            alerts.append(f"calendar mirror: {behind} min behind the last published feed")
    except FileNotFoundError:
        if not records:
            alerts.append("calendar mirror: no state file - it has never completed")
    except OSError:
        alerts.append("calendar mirror: could not read the mirror state")

    alerts.extend(publisher_alerts(newest, Path(args.publish_state), now,
                                   dt.timedelta(hours=args.feed_max_hours)))

    # Deep verify, at most once a day.
    today = now.date().isoformat()
    if not args.no_verify and cursor.get("verified_on") != today:
        extra: list[str] = []
        if args.pairs:
            extra += ["--pairs", args.pairs]
        extra += ["--state", args.state_arg or args.state]
        code = run_verify(args.verify, extra)
        if code == 127:
            # Count the attempt, or the same alert repeats every hour.
            cursor["verified_on"] = today
            alerts.append("calendar mirror: could not run the daily deep check")
        else:
            # Mark the day whatever the code: a check that keeps failing is one
            # alert a day, not one every hour. 127 means the check never ran.
            cursor["verified_on"] = today
            if code != 0:
                alerts.append(f"calendar mirror: daily deep check {phrase(code)}")

    # Canary, at most once a day: one event that must survive publisher,
    # mirror and (after cutover) Home Assistant.
    if args.canary_summary:
        last = cursor.get("canary_on")
        stale = True
        if last:
            try:
                stale = now - dt.datetime.fromisoformat(last) > CANARY_TTL
            except ValueError:
                stale = True
        if stale:
            found = check_canary(args.canary_summary, args.canary_collection)
            if found is True:
                cursor["canary_on"] = now.isoformat()
            elif found is False:
                alerts.append("calendar mirror: the canary event is missing from the calendar")
                cursor["canary_on"] = now.isoformat()
            else:
                # Mark the day anyway: an unreachable calendar is one alert, not
                # one every hour until midnight.
                cursor["canary_on"] = now.isoformat()
                alerts.append("calendar mirror: could not check the canary event")

    # Keep the spool bounded: once read and counted, an oversized file is moved
    # aside rather than deleted, so a human can still look at it.
    try:
        if spool.exists() and spool.stat().st_size > args.spool_max_bytes:
            rotated = spool.with_suffix(spool.suffix + ".1")
            # Everything in it has just been read into `records`, so rotating
            # loses nothing: the cursor starts clean on the next file.
            os.replace(spool, rotated)
            cursor["spool_offset"] = 0
            cursor["spool_inode"] = ""
    except OSError:
        pass

    save_cursor(cursor_path, cursor)

    for line in alerts:
        print(line)
    return 1 if alerts else 0


if __name__ == "__main__":
    sys.exit(main())
