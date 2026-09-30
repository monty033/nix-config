#!/usr/bin/env python3
"""
Family Calendar Router
======================
Ingests source calendars (Proton iCal, Google Calendar, SDST school iCal),\nparses #hashtags from event titles and descriptions, and outputs per-person +\nfamily iCal files.

Hashtags: #patrick #lina #aleandra #emma #isabella #juliana

Routing:
  0 hashtags → Family calendar
  1 hashtag  → that person's calendar
  2+ hashtags → Family calendar + each tagged person's calendar

Output: 7 iCal files → scp to Home Assistant www/ → HA serves as calendar feeds
"""

import sys
import os
import re
import hashlib
import shlex
import subprocess
import time
from datetime import datetime, timedelta, date, timezone
from zoneinfo import ZoneInfo
from collections import defaultdict
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

# --- Configuration -----------------------------------------------------------

FAMILY_MEMBERS = {
    "patrick": "Patrick",
    "lina": "Lina",
    "aleandra": "Aleandra",
    "emma": "Emma",
    "isabella": "Isabella",
    "juliana": "Juliana",
    "family": "Family",
}

# Nickname aliases — maps hashtag to canonical FAMILY_MEMBERS key
HASHTAG_ALIASES = {
    "ali": "aleandra",
    "bella": "isabella",
}

# Set by tests or callers that need an explicit destination. Otherwise resolve
# HOME at write time so importing this module does not freeze runtime state.
OUTPUT_DIR = None
PROTON_ICAL_URL_FILE = os.environ.get(
    "PROTON_ICAL_URL_FILE",
    "/run/secrets/calendar-proton-url",
)

# Lina's Google Calendar iCal URL is rendered by sops-nix at runtime.
LINA_ICAL_URL_FILE = os.environ.get(
    "LINA_ICAL_URL_FILE",
    "/run/secrets/calendar-google-url",
)

# SDST (Springfield School District) public iCal feeds. Three feeds together
# reproduce the single district-wide view that the old departments=1622043 URL
# used to return before that link 404'd. Each URL is stored in a gitignored
# runtime file so the URLs can change without editing source.
SDST_ICAL_URL_FILES = [
    os.path.expanduser("~/.hermes/workspace/.sdst_calendar_url_district"),
    os.path.expanduser("~/.hermes/workspace/.sdst_calendar_url_enf"),
    os.path.expanduser("~/.hermes/workspace/.sdst_calendar_url_erd"),
]

# Number of days ahead to include in output calendars
LOOKAHEAD_DAYS = 60

# Home Assistant SCP target
HA_TARGET = "root@192.168.86.100:/config/www"

# Public school-calendar publication target. Bifrost's existing Caddy
# virtualHost serves /var/www/ical at https://ical.montycasa.com/.
PUBLIC_SCHOOL_HOST = "patrick@bifrost"
PUBLIC_SCHOOL_PATH = "/var/www/ical/school.ics"

# Local timezone
LOCAL_TZ = ZoneInfo("America/New_York")

# Direct source fetches are retried during one run, but never fall back to a
# stale local calendar snapshot. The next four-hour timer run is the next
# recovery opportunity after a permanent failure.
FETCH_RETRY_DELAYS = (2, 5, 15)
FETCH_TIMEOUT_SECONDS = 30

# -----------------------------------------------------------------------------


def unfold_ical(text: str) -> str:
    """Unfold iCal continuation lines (lines starting with space/tab)."""
    lines = text.splitlines()
    unfolded = []
    for line in lines:
        if unfolded and line and line[0] in (" ", "\t"):
            unfolded[-1] += line[1:]
        else:
            unfolded.append(line)
    return "\n".join(unfolded)


def parse_ical_file(path: str) -> list[dict]:
    """Parse an iCal file and return list of event dicts."""
    import icalendar

    with open(path, "r") as f:
        raw = f.read()

    cal = icalendar.Calendar.from_ical(unfold_ical(raw))
    events = []

    for component in cal.walk("VEVENT"):
        event = {
            "uid": str(component.get("uid", "")),
            "summary": str(component.get("summary", "")),
            "description": str(component.get("description", "")),
            "location": str(component.get("location", "")),
            "start": None,
            "end": None,
            "all_day": False,
            "rrule": None,
            "exdate": None,
            "rdate": None,
            "recurrence_id": None,
            "source": path,
        }

        dtstart = component.get("dtstart")
        dtend = component.get("dtend")

        if dtstart:
            event["start"] = dtstart.dt
            if isinstance(dtstart.dt, date) and not isinstance(dtstart.dt, datetime):
                event["all_day"] = True
                event["start"] = datetime.combine(
                    dtstart.dt, datetime.min.time()
                )

        if dtend:
            event["end"] = dtend.dt
            if isinstance(dtend.dt, date) and not isinstance(dtend.dt, datetime):
                # iCal all-day DTEND is exclusive — store as-is, don't subtract
                event["end"] = datetime.combine(
                    dtend.dt, datetime.min.time()
                )
            if not event["start"]:
                event["start"] = event["end"] - timedelta(hours=1)

        if not event["start"]:
            continue

        # Preserve recurrence rules for output
        for prop_name in ("rrule", "exdate", "rdate", "recurrence-id"):
            if prop_name in component:
                prop = component[prop_name]
                # vDDDTypes objects contain .dts (list of datetime/date)
                if hasattr(prop, 'dts'):
                    event[prop_name] = list(prop.dts)
                else:
                    event[prop_name] = prop

        # Make datetime offset-aware using local timezone (handles DST correctly)
        if isinstance(event["start"], datetime) and event["start"].tzinfo is None:
            event["start"] = event["start"].replace(tzinfo=LOCAL_TZ)
        if isinstance(event["end"], datetime) and event["end"].tzinfo is None:
            event["end"] = event["end"].replace(tzinfo=LOCAL_TZ)

        events.append(event)

    return events


def parse_ical_string(raw: str, source: str = "inline") -> list[dict]:
    """Parse an iCal string directly (no file)."""
    import icalendar
    import tempfile

    # icalendar.from_ical accepts bytes — write to temp file for parse_ical_file reuse
    with tempfile.NamedTemporaryFile(mode="w", suffix=".ics", delete=False) as f:
        f.write(raw)
        tmp_path = f.name
    try:
        events = parse_ical_file(tmp_path)
    finally:
        os.unlink(tmp_path)
    for e in events:
        e["source"] = source
    return events


def extract_hashtags(summary: str, description: str) -> set[str]:
    """Extract family member hashtags from event title and description.
    Resolves nickname aliases (e.g., #ali → aleandra)."""
    text = f"{summary} {description}".lower()
    found = set()
    # Check canonical tags
    for tag in FAMILY_MEMBERS:
        if re.search(rf"(?<![a-z])#{re.escape(tag)}(?![a-z])", text):
            found.add(tag)
    # Check aliases and map to canonical
    for alias, canonical in HASHTAG_ALIASES.items():
        if re.search(rf"(?<![a-z])#{re.escape(alias)}(?![a-z])", text):
            found.add(canonical)
    return found

def make_uid(source: str, summary: str, start) -> str:
    """Generate a deterministic UID from source + summary + start time."""
    raw = f"{source}|{summary}|{start}"
    return hashlib.sha256(raw.encode()).hexdigest()[:32]


def route_events(events: list[dict]) -> dict[str, list[dict]]:
    """
    Route events to calendars based on hashtags.
    Recurring events are always included regardless of DTSTART age.
    Returns: {calendar_name: [events]}
    """
    calendars = defaultdict(list)
    now = datetime.now(timezone.utc)
    cutoff = now + timedelta(days=LOOKAHEAD_DAYS)
    past_cutoff = now - timedelta(days=7)

    for event in events:
        has_rrule = event.get("rrule") is not None

        if not has_rrule:
            # One-off events: skip if too old or too far in the future
            if event["start"] and event["start"] < past_cutoff:
                continue
            if event["start"] and event["start"] > cutoff:
                continue
        # Recurring events: always include (RRULE handles the date range)

        tags = extract_hashtags(
            event.get("summary", ""),
            event.get("description", ""),
        )

        if len(tags) == 0:
            # No hashtags — Family calendar
            calendars["family"].append(event)
        elif len(tags) == 1:
            person = list(tags)[0]
            calendars[person].append(event)
        else:
            # 2+ hashtags → Family + each tagged person
            calendars["family"].append(event)
            for person in tags:
                if person != "family":
                    calendars[person].append(event)

    return dict(calendars)


def generate_ical(calendar_name: str, events: list[dict]) -> str:
    """Generate an iCal string for a calendar."""
    import icalendar

    cal = icalendar.Calendar()
    cal.add("prodid", "-//Family Calendar Router//hermes//EN")
    cal.add("version", "2.0")
    cal.add("calscale", "GREGORIAN")
    cal.add("method", "PUBLISH")
    display_name = FAMILY_MEMBERS.get(calendar_name, calendar_name.title())
    cal.add("x-wr-calname", f"{display_name}")
    cal.add("x-wr-timezone", "America/New_York")
    cal.add("refresh-interval;value=duration", "PT24H")

    seen_uids = set()
    for event in events:
        summary = event.get("summary", "Untitled")
        start = event.get("start")
        source = event.get("source", "")

        uid = event.get("uid", "")
        if not uid:
            uid = make_uid(source, summary, start)
        if uid in seen_uids:
            continue
        seen_uids.add(uid)

        vevent = icalendar.Event()
        vevent.add("uid", uid)
        vevent.add("summary", summary)

        # Use a stable DTSTAMP: the event's original DTSTART, not wall-clock now.
        # This prevents phantom-change churn on every cron run.
        if start:
            vevent.add("dtstamp", start)
        else:
            vevent.add("dtstamp", datetime.now(timezone.utc))

        if event.get("description"):
            vevent.add("description", event["description"])
        if event.get("location"):
            vevent.add("location", event["location"])

        # Copy recurrence rules from source
        for prop_name in ("rrule", "exdate", "rdate", "recurrence-id"):
            val = event.get(prop_name)
            if val:
                # Fix RRULE UNTIL date-type mismatch: if DTSTART is datetime
                # but UNTIL is date-only, convert UNTIL to datetime.
                # (Google Calendar sometimes emits this invalid combination,
                #  and Home Assistant's parser rejects it.)
                if prop_name == "rrule" and "UNTIL" in val:
                    start = event.get("start")
                    if isinstance(start, datetime) and not event.get("all_day"):
                        # Fix RRULE UNTIL date-type mismatch: DTSTART is
                        # datetime but UNTIL is date-only → convert to datetime.
                        # (Skip all-day events — DATE DTSTART + DATE UNTIL is correct.)
                        fixed_until = []
                        for u in val["UNTIL"]:
                            if isinstance(u, date) and not isinstance(u, datetime):
                                u = datetime.combine(
                                    u, datetime.max.time()
                                ).replace(tzinfo=timezone.utc)
                            fixed_until.append(u)
                        val["UNTIL"] = fixed_until

                try:
                    vevent.add(prop_name, val)
                except (ValueError, TypeError):
                    pass  # skip unparseable recurrence prop

        if event.get("all_day"):
            start_dt = event["start"]
            if isinstance(start_dt, datetime):
                start_dt = start_dt.date()
            vevent.add("dtstart", icalendar.vDate(start_dt))

            end_dt = event.get("end", start_dt + timedelta(days=1))
            if isinstance(end_dt, datetime):
                end_dt = end_dt.date()
            vevent.add("dtend", icalendar.vDate(end_dt))
        else:
            vevent.add("dtstart", event["start"])
            if event.get("end"):
                vevent.add("dtend", event["end"])
            else:
                vevent.add("dtend", event["start"] + timedelta(hours=1))

        cal.add_component(vevent)

    return cal.to_ical().decode("utf-8")


def write_outputs(calendars: dict[str, list[dict]]) -> dict[str, str]:
    """Write iCal files to OUTPUT_DIR. Returns {name: filepath}."""
    output_dir = OUTPUT_DIR or os.path.expanduser("~/.hermes/workspace/calendars")
    os.makedirs(output_dir, exist_ok=True)
    outputs = {}

    for name in list(FAMILY_MEMBERS.keys()) + ["family"]:
        events = calendars.get(name, [])
        ical_str = generate_ical(name, events)
        filepath = os.path.join(output_dir, f"{name}.ics")
        with open(filepath, "w") as f:
            f.write(ical_str)
        outputs[name] = filepath

    return outputs


def write_school_output(events: list[dict]) -> str:
    """Write the filtered school calendar used by the public publication."""
    output_dir = OUTPUT_DIR or os.path.expanduser("~/.hermes/workspace/calendars")
    os.makedirs(output_dir, exist_ok=True)
    filepath = os.path.join(output_dir, "school.ics")
    with open(filepath, "w") as f:
        f.write(generate_ical("school", events))
    return filepath


def fetch_remote_ical(url: str, source: str) -> str:
    """Fetch and validate a remote iCal document without logging its URL."""
    for attempt in range(len(FETCH_RETRY_DELAYS) + 1):
        try:
            request = Request(
                url,
                headers={"User-Agent": "family-calendar-router/1.0"},
            )
            with urlopen(request, timeout=FETCH_TIMEOUT_SECONDS) as response:
                raw = response.read().decode("utf-8-sig")
            if not raw.lstrip().startswith("BEGIN:VCALENDAR"):
                raise ValueError("response was not an iCalendar document")
            return raw
        except HTTPError as exc:
            retryable = exc.code in {408, 429} or exc.code >= 500
            detail = f"HTTP {exc.code}"
        except (URLError, TimeoutError) as exc:
            retryable = True
            detail = type(exc).__name__
        except ValueError:
            # urllib may include the full malformed URL in ValueError text.
            retryable = True
            detail = "invalid URL or iCalendar response"

        if attempt < len(FETCH_RETRY_DELAYS) and retryable:
            delay = FETCH_RETRY_DELAYS[attempt]
            print(
                f"  {source}: fetch attempt {attempt + 1} failed ({detail}); retrying in {delay}s",
                file=sys.stderr,
            )
            time.sleep(delay)
            continue
        raise RuntimeError(f"{detail} after {attempt + 1} attempt(s)")

    raise RuntimeError(f"{source} fetch failed")


def fetch_proton() -> list[dict]:
    """Fetch events directly from the Proton iCal URL."""
    if not os.path.exists(PROTON_ICAL_URL_FILE):
        raise RuntimeError(f"Proton URL secret file not found: {PROTON_ICAL_URL_FILE}")
    with open(PROTON_ICAL_URL_FILE) as f:
        ical_url = f.read().strip()
    if not ical_url:
        raise RuntimeError("Proton URL secret file is empty")
    return parse_ical_string(
        fetch_remote_ical(ical_url, "Proton"),
        source="proton",
    )


def fetch_google() -> list[dict]:
    """Fetch events from Lina's Google Calendar iCal feed."""
    if not os.path.exists(LINA_ICAL_URL_FILE):
        raise RuntimeError(f"Google URL secret file not found: {LINA_ICAL_URL_FILE}")
    with open(LINA_ICAL_URL_FILE) as f:
        ical_url = f.read().strip()
    if not ical_url:
        raise RuntimeError("Google URL secret file is empty")
    return parse_ical_string(
        fetch_remote_ical(ical_url, "Google"),
        source="google",
    )


def school_event_key(event: dict) -> tuple[str, str, str, str]:
    """Return a source-independent identity for a school event.

    SDST publishes the same district-wide event in multiple school feeds with
    different UIDs. UID is therefore not sufficient for cross-feed merging.
    Keep location in the identity so two same-named events at different
    schools remain separate.
    """
    def normalize(value: object) -> str:
        return " ".join(str(value or "").split()).casefold()

    return (
        normalize(event.get("summary")),
        normalize(event.get("start")),
        normalize(event.get("end")),
        normalize(event.get("location")),
    )


def fetch_school() -> list[dict]:
    """Fetch events from all SDST iCal feeds (District, ENF, ERD), auto-tagging
    ENF/ERD-relevant events with #family so they route to the Family calendar.

    Each entry in SDST_ICAL_URL_FILES points to a gitignored runtime file
    containing one iCal URL. The feeds together reproduce the single
    district-wide view that the old departments=1622043 URL used to return
    before that link 404'd; the per-event keyword filter is unchanged."""
    # Filter: family-relevant event types
    FAMILY_KEYWORDS = [
        "school closed", "schools closed", "holiday", "early dismissal",
        "teacher inservice", "no school", "last student day",
        "memorial day", "labor day", "no student", "district closed",
    ]
    # ENF/ERD-specific events (not closures, but family should know)
    ENF_ERD_EVENT_KEYWORDS = [
        "report card", "picture day", "color day", "2nd grade parade",
        "festival of the arts", "end of",
    ]
    # Kindergarten events — always include (K is at Enfield)
    KINDERGARTEN_KEYWORDS = ["kindergarten"]
    # Patterns to detect ENF/ERD mention
    ENF_ERD_PATTERNS = [
        r"\bENF\b", r"\bERD\b", r"\bEnfield\b", r"\bErdenheim\b",
    ]

    def tag_event(event: dict) -> bool:
        summary = event.get("summary", "")
        summary_lower = summary.lower()
        desc = event.get("description", "")

        is_family_type = any(kw in summary_lower for kw in FAMILY_KEYWORDS)
        is_enf_erd = any(re.search(pat, summary) for pat in ENF_ERD_PATTERNS)
        is_enf_erd_event = is_enf_erd and any(
            kw in summary_lower for kw in ENF_ERD_EVENT_KEYWORDS
        )
        is_kindergarten = any(kw in summary_lower for kw in KINDERGARTEN_KEYWORDS)
        mentions_hs_ms = bool(
            re.search(r"\b(HS|MS|High School|Middle School)\b", summary)
        )
        is_district_wide = not is_enf_erd and not mentions_hs_ms

        include = False
        if is_family_type and (is_enf_erd or is_district_wide):
            include = True
        elif is_enf_erd_event:
            include = True
        elif is_kindergarten:
            include = True

        if include:
            tag = " #family"
            event["description"] = desc + tag if desc else tag.strip()
            return True
        return False

    all_events: list[dict] = []
    feeds_loaded = 0
    feed_failures: list[str] = []

    for url_file in SDST_ICAL_URL_FILES:
        if not os.path.exists(url_file):
            print(f"  SDST: URL file missing: {url_file}", file=sys.stderr)
            feed_failures.append(url_file)
            continue
        with open(url_file) as f:
            ical_url = f.read().strip()
        if not ical_url:
            print(f"  SDST: URL file empty: {url_file}", file=sys.stderr)
            feed_failures.append(url_file)
            continue

        result = None
        failure = "unknown failure"
        for attempt in range(len(FETCH_RETRY_DELAYS) + 1):
            try:
                candidate = subprocess.run(
                    ["curl", "-s", "-L", "--max-time", "30", ical_url],
                    capture_output=True,
                    text=True,
                    timeout=35,
                )
                if candidate.returncode == 0 and candidate.stdout.strip().startswith(
                    "BEGIN:VCALENDAR"
                ):
                    result = candidate
                    break
                failure = (
                    f"curl exit {candidate.returncode}"
                    if candidate.returncode
                    else "non-iCal content"
                )
            except subprocess.TimeoutExpired:
                failure = "curl timeout"

            if attempt < len(FETCH_RETRY_DELAYS):
                delay = FETCH_RETRY_DELAYS[attempt]
                print(
                    f"  SDST: fetch attempt {attempt + 1} failed ({failure}); "
                    f"retrying in {delay}s",
                    file=sys.stderr,
                )
                time.sleep(delay)

        if result is None:
            print(f"  SDST: feed failed after retries: {url_file}", file=sys.stderr)
            feed_failures.append(url_file)
            continue

        try:
            feed_events = parse_ical_string(result.stdout, source="sdst")
        except (ValueError, TypeError) as exc:
            print(f"  SDST: invalid iCal from {url_file}: {type(exc).__name__}", file=sys.stderr)
            feed_failures.append(url_file)
            continue
        all_events.extend(feed_events)
        print(f"  SDST: {url_file} → {len(feed_events)} events", file=sys.stderr)
        feeds_loaded += 1

    if feed_failures:
        print(
            f"ERROR: SDST: {len(feed_failures)} feed(s) failed; refusing partial publication",
            file=sys.stderr,
        )
        return []
    if feeds_loaded == 0:
        print("ERROR: SDST: no feeds loaded", file=sys.stderr)
        return []

    # Auto-tag and retain only matching events. Untagged school events must
    # not flow into route_events(), where untagged events intentionally go to
    # the Family calendar.
    selected_events = []
    seen_event_keys: set[tuple[str, str, str, str]] = set()
    for event in all_events:
        if not tag_event(event):
            continue
        event_key = school_event_key(event)
        if event_key in seen_event_keys:
            continue
        seen_event_keys.add(event_key)
        selected_events.append(event)

    print(
        f"  SDST: {len(all_events)} events total, "
        f"{len(selected_events)} unique events selected for Family",
        file=sys.stderr,
    )
    return selected_events


def scp_to_ha(outputs: dict[str, str]) -> bool:
    """Atomic SCP deploy: upload to .new files, then mv all at once."""
    if not HA_TARGET:
        print("SKIP: HA_TARGET not set", file=sys.stderr)
        return False

    host_part, path_part = HA_TARGET.split(":", 1)
    remote_dir = f"{path_part}/calendars"

    # Ensure target directory exists on HA
    try:
        subprocess.run(
            ["ssh", "-o", "ConnectTimeout=10", host_part,
             f"mkdir -p {remote_dir}"],
            check=True, timeout=15,
        )
    except subprocess.CalledProcessError as e:
        print(f"  ✗ mkdir failed: {e}", file=sys.stderr)
        return False

    # Phase 1: Upload all files as .new
    uploaded = []

    def cleanup_staged_uploads() -> None:
        cleanup_targets = " ".join(
            f"{shlex.quote(remote_dir)}/{shlex.quote(name)}.ics.new"
            for name in outputs
        )
        try:
            subprocess.run(
                [
                    "ssh",
                    "-o",
                    "ConnectTimeout=10",
                    host_part,
                    f"rm -f -- {cleanup_targets}",
                ],
                check=False,
                timeout=15,
            )
        except Exception as cleanup_error:
            print(f"  ⚠ staging cleanup failed: {cleanup_error}", file=sys.stderr)

    for name, filepath in outputs.items():
        dest = f"{HA_TARGET}/calendars/{name}.ics.new"
        try:
            subprocess.run(
                ["scp", "-O", "-o", "ConnectTimeout=10", filepath, dest],
                check=True, timeout=30,
            )
            uploaded.append(name)
            print(f"  ↑ {name}.ics.new", file=sys.stderr)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
            print(f"  ✗ upload {name}.ics failed: {e}", file=sys.stderr)
            cleanup_staged_uploads()
            return False

    # Phase 2: Replace the complete feed set with rollback on any failed move.
    # Individual files are used because the directory also contains unrelated
    # feeds; track each successful move so rollback never deletes an untouched
    # live feed.
    names = " ".join(shlex.quote(n) for n in uploaded)
    remote_script = f'''set -eu
remote_dir={shlex.quote(remote_dir)}
backup_dir="$remote_dir/.calendar-previous-$$"
moved_old=""
deployed=""
rm -rf "$backup_dir"
mkdir "$backup_dir"
rollback() {{
  status=$?
  trap - EXIT
  if [ "$status" -ne 0 ]; then
    for name in $deployed; do
      rm -f "$remote_dir/$name.ics"
    done
    for name in $moved_old; do
      if [ -f "$backup_dir/$name.ics" ]; then
        mv "$backup_dir/$name.ics" "$remote_dir/$name.ics"
      fi
    done
    for name in {names}; do
      rm -f "$remote_dir/$name.ics.new"
    done
  fi
  rm -rf "$backup_dir"
  exit "$status"
}}
trap rollback EXIT
for name in {names}; do
  if [ -f "$remote_dir/$name.ics" ]; then
    mv "$remote_dir/$name.ics" "$backup_dir/$name.ics"
    moved_old="$moved_old $name"
  fi
done
for name in {names}; do
  mv "$remote_dir/$name.ics.new" "$remote_dir/$name.ics"
  deployed="$deployed $name"
done
trap - EXIT
rm -rf "$backup_dir"'''
    try:
        subprocess.run(
            ["ssh", "-o", "ConnectTimeout=10", host_part, remote_script],
            check=True, timeout=15,
        )
        for name in uploaded:
            print(f"  ✓ {name}.ics", file=sys.stderr)
    except subprocess.CalledProcessError as e:
        print(f"  ✗ atomic rename failed: {e}", file=sys.stderr)
        return False

    # Remove only stale family feeds; leave unrelated calendars in the directory.
    expected = {f"{n}.ics" for n in outputs}
    known_family_feeds = {f"{n}.ics" for n in FAMILY_MEMBERS}
    try:
        result = subprocess.run(
            ["ssh", "-o", "ConnectTimeout=10", host_part,
             f"ls {remote_dir}/"],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode == 0:
            for fname in result.stdout.splitlines():
                fname = fname.strip()
                if fname in known_family_feeds - expected:
                    subprocess.run(
                        ["ssh", "-o", "ConnectTimeout=10", host_part,
                         f"rm {remote_dir}/{fname}"],
                        timeout=10,
                    )
                    print(f"  ✗ removed stale: {fname}", file=sys.stderr)
    except Exception:
        pass  # non-critical cleanup

    return True


def scp_school_to_public(filepath: str) -> bool:
    """Upload the school feed to Bifrost, then atomically publish it."""
    temporary_path = f"{PUBLIC_SCHOOL_PATH}.new"
    published = False
    ssh_options = [
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "ConnectTimeout=10",
    ]
    try:
        subprocess.run(
            ["scp", *ssh_options, filepath,
             f"{PUBLIC_SCHOOL_HOST}:{temporary_path}"],
            check=True,
            timeout=30,
        )
        subprocess.run(
            ["ssh", *ssh_options, PUBLIC_SCHOOL_HOST,
             f"chmod 0644 {temporary_path} && mv -f {temporary_path} {PUBLIC_SCHOOL_PATH}"],
            check=True,
            timeout=15,
        )
        published = True
        print("  ✓ https://ical.montycasa.com/school.ics", file=sys.stderr)
        return True
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        print(f"  ✗ public school-calendar publication failed: {e}", file=sys.stderr)
        return False
    finally:
        if not published:
            try:
                subprocess.run(
                    ["ssh", *ssh_options, PUBLIC_SCHOOL_HOST,
                     f"rm -f {temporary_path}"],
                    timeout=15,
                )
            except Exception:
                pass


def main():
    # All progress output goes to stderr — stdout is reserved for errors only.
    # Cron job is no_agent=true with deliver=origin, so empty stdout = silent success.
    print("Family Calendar Router", file=sys.stderr)
    print("======================", file=sys.stderr)
    print(file=sys.stderr)

    # Fetch sources
    print("Fetching calendars...", file=sys.stderr)
    try:
        proton_events = fetch_proton()
    except RuntimeError as exc:
        print(f"ERROR: Proton fetch failed: {exc}", file=sys.stderr)
        return 1
    print(f"  Proton: {len(proton_events)} events", file=sys.stderr)

    try:
        google_events = fetch_google()
    except RuntimeError as exc:
        print(f"ERROR: Google fetch failed: {exc}", file=sys.stderr)
        return 1
    print(f"  Google: {len(google_events)} events", file=sys.stderr)

    school_events = fetch_school()
    print(f"  School: {len(school_events)} events", file=sys.stderr)

    all_events = proton_events + google_events + school_events
    print(f"  Total:  {len(all_events)} events", file=sys.stderr)
    print(file=sys.stderr)

    # Route
    print("Routing by hashtag...", file=sys.stderr)
    calendars = route_events(all_events)
    school_calendar = route_events(school_events).get("family", [])
    if not school_calendar:
        print("ERROR: filtered school calendar contains no events", file=sys.stderr)
        return 1

    counts = {}
    for name, events in sorted(calendars.items()):
        counts[name] = len(events)
        display = FAMILY_MEMBERS.get(name, "Family")
        print(f"  {display:12} {len(events):4} events", file=sys.stderr)

    # Count untagged upcoming events (routed to Family)
    now = datetime.now(timezone.utc)
    upcoming_untagged = 0
    for event in all_events:
        has_rrule = event.get("rrule") is not None
        in_window = (
            has_rrule or
            (event["start"] and event["start"] >= (now - timedelta(days=7)))
        )
        if in_window and not extract_hashtags(
            event.get("summary", ""), event.get("description", "")
        ):
            upcoming_untagged += 1
    if upcoming_untagged:
        print(f"  {'untagged':12} {upcoming_untagged:4} events → Family", file=sys.stderr)
    print(file=sys.stderr)

    # Generate iCal files
    print("Generating iCal files...", file=sys.stderr)
    outputs = write_outputs(calendars)
    school_output = write_school_output(school_calendar)
    for name, path in outputs.items():
        size = os.path.getsize(path)
        print(f"  {name}.ics  {size:6} bytes", file=sys.stderr)
    print(f"  school.ics {os.path.getsize(school_output):6} bytes", file=sys.stderr)

    # Deploy to HA
    if HA_TARGET:
        print(file=sys.stderr)
        print("Deploying to HA...", file=sys.stderr)
        if scp_to_ha(outputs):
            print("  Done.", file=sys.stderr)
        else:
            print("  Failed.", file=sys.stderr)
            return 1

    print("\nPublishing school calendar to Bifrost...", file=sys.stderr)
    if not scp_school_to_public(school_output):
        return 1

    print(file=sys.stderr)
    print(f"Done. {sum(counts.values())} events routed to {len(outputs)} calendars.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
