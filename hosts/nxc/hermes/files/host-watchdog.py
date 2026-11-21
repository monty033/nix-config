#!/usr/bin/env python3
"""Outside-the-agent check: is the failure loop still running?

The hourly notifier is the only path cron failures travel. If it stops, silence
looks identical to a clean day, so this script watches the watcher. It runs from
a systemd timer, not from cron and not from the agent, so a wedged gateway or a
stalled cron thread cannot suppress its own alarm.

Two signals:
  * the notifier's heartbeat file, which goes stale when the loop stops;
  * the gateway's /health endpoint, so a dead process is named as such.

Silent while healthy. One alert per problem kind per repeat window (6h by
default), then one recovery message once the problems have stayed clear for two
consecutive ticks, so a long outage is a few pages rather than one per tick and
a flapping gateway does not alternate.

A reboot leaves an old heartbeat on disk, so one tick per outage is forgiven:
while the host has been up less than one window, a heartbeat that predates this
boot suppresses the alarm once, however stale it is -- a long shutdown must not
page with a message blaming cron. The forgiven run is recorded, so a second boot
with the same stale heartbeat reports normally and a dead collector pages within
fifteen minutes; a fresh run re-arms the grace. A suppressed tick is never treated
as healthy: it neither advances the recovery streak nor clears an open alert.
A heartbeat up to five minutes in the future is tolerated as clock noise; past
that it is reported, because a run stamped ahead of now cannot be trusted.

TELEGRAM_BOT_TOKEN comes from the systemd EnvironmentFile; the token is never
printed. --dry-run prints the message instead of sending it and never writes the
state file, so a hand run cannot silence or fake a real alarm.

Flags: --skip-heartbeat / --skip-health isolate one signal (never both at once),
--health-url and --max-age-minutes retune the check, --repeat-hours sets the
de-dup window. WATCHDOG_CHAT_ID, WATCHDOG_HEARTBEAT and WATCHDOG_STATE override
the defaults.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

HEARTBEAT = os.environ.get("WATCHDOG_HEARTBEAT",
                           "/var/lib/hermes/.hermes/state/failure-triage-heartbeat.json")
STATE = os.environ.get("WATCHDOG_STATE",
                       "/var/lib/hermes/.hermes/state/host-watchdog.json")
HEALTH_URL = "http://127.0.0.1:8642/health"
CHAT_ID = os.environ.get("WATCHDOG_CHAT_ID", "748642877")
RECOVERY_STREAK = 2       # healthy ticks in a row before "it's back" is sent
FUTURE_TOLERANCE = 5.0    # minutes a clock may run ahead before it is a finding
TOKEN_SHAPE = re.compile(r"^\d+:[A-Za-z0-9_-]+$")
WARMUP_MINUTES = 150.0    # set from --max-age-minutes at runtime
ABSENT = "absent"         # grace marker for a heartbeat with no usable run
KNOWN_KINDS = ("heartbeat", "gateway")


def now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def parse_ts(value) -> dt.datetime | None:
    """An aware UTC datetime from a stored value, or None when it is unusable."""
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        stamp = dt.datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=dt.timezone.utc)
    return stamp


def uptime_minutes() -> float | None:
    try:
        with open("/proc/uptime") as fh:
            return float(fh.read().split()[0]) / 60
    except (OSError, ValueError, IndexError):
        return None


def load_json(path: str) -> dict:
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def save_state(state: dict) -> bool:
    """Atomic write: a torn state file would silently drop the de-dup window."""
    tmp = STATE + ".tmp"
    try:
        os.makedirs(os.path.dirname(STATE), exist_ok=True)
        with open(tmp, "w") as fh:
            json.dump(state, fh)
        os.replace(tmp, STATE)
        return True
    except OSError as exc:
        print(f"could not write state: {exc}", file=sys.stderr)
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False


def forgiven_once(state: dict, marker: str, age_min: float | None) -> bool:
    """True when this stale heartbeat is explained by the boot and not yet forgiven.

    All of these must hold:
      * the host has been up less than one window;
      * the run existed before this boot (an absent file counts);
      * this exact run has not been forgiven before.

    How stale the run was at boot time is deliberately NOT a condition. A
    heartbeat that stopped because the host went down looks identical to one
    that stopped because the collector died, and only systemd knows when the
    shutdown began. Testing staleness instead would page after every shutdown
    longer than a window -- the common case -- with a message blaming cron. The
    cost of forgiving is bounded: one tick, once per run, so a collector that is
    genuinely dead still pages within fifteen minutes of the next boot.
    """
    up = uptime_minutes()
    if up is None or up >= WARMUP_MINUTES:
        return False
    return state.get("grace_spent_for") != marker


def heartbeat_problem(state: dict) -> tuple[str | None, bool, str | None]:
    """Return (problem message or None, suppressed-for-this-tick, grace marker)."""
    def excused(marker: str) -> tuple[str | None, bool, str | None]:
        if forgiven_once(state, marker, None):
            return None, True, marker
        return None, False, None

    if not os.path.exists(HEARTBEAT):
        head, flag, mark = excused(ABSENT)
        if flag:
            return head, flag, mark
        return (f"no heartbeat file at {HEARTBEAT} — the failure collector has "
                f"recorded no run"), False, None

    hb = load_json(HEARTBEAT)
    if not hb:
        head, flag, mark = excused(ABSENT)
        if flag:
            return head, flag, mark
        return f"heartbeat file at {HEARTBEAT} is unreadable or empty", False, None

    raw_stamp = hb.get("last_run")
    last = parse_ts(raw_stamp)
    if last is None:
        head, flag, mark = excused(ABSENT)
        if flag:
            return head, flag, mark
        return f"heartbeat timestamp at {HEARTBEAT} is unreadable", False, None

    age_min = (now() - last).total_seconds() / 60
    if age_min < -FUTURE_TOLERANCE:
        return (f"heartbeat timestamp at {HEARTBEAT} is {-age_min:.0f} min in the "
                f"future"), False, None
    if age_min <= WARMUP_MINUTES:
        return None, False, None

    marker = str(raw_stamp)
    if forgiven_once(state, marker, age_min):
        return None, True, marker
    return (f"failure collector last ran {age_min:.0f} min ago "
            f"(limit {WARMUP_MINUTES:.0f}) — cron failures are not being reported"), False, None


def gateway_problem(url: str) -> str | None:
    try:
        with urllib.request.urlopen(url, timeout=8) as resp:
            if resp.status == 200:
                return None
            return f"gateway /health returned {resp.status}"
    except urllib.error.HTTPError as exc:
        return f"gateway /health returned {exc.code}"
    except Exception as exc:  # noqa: BLE001 - any failure is the finding
        return f"gateway /health unreachable ({type(exc).__name__})"


def send(text: str, dry_run: bool) -> bool:
    if dry_run:
        print("[dry-run] would send:\n" + text)
        return True
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
    if not token or not TOKEN_SHAPE.match(token):
        # Shape-checked before it reaches a URL, so a malformed token cannot
        # surface in a traceback that carries the request.
        print("TELEGRAM_BOT_TOKEN is missing or malformed; cannot alert", file=sys.stderr)
        return False
    try:
        body = urllib.parse.urlencode({"chat_id": CHAT_ID, "text": text,
                                       "disable_web_page_preview": "true"}).encode()
        req = urllib.request.Request(f"https://api.telegram.org/bot{token}/sendMessage",
                                     data=body)
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.status == 200
    except Exception as exc:  # noqa: BLE001
        print(f"telegram send failed: {type(exc).__name__}", file=sys.stderr)
        return False


def clean_alerted(raw) -> dict[str, dt.datetime]:
    """Keep only usable timestamps; anything else counts as never alerted."""
    if not isinstance(raw, dict):
        return {}
    out = {}
    for kind, value in raw.items():
        stamp = parse_ts(value)
        if stamp is not None:
            out[str(kind)] = stamp
    return out


def recovery_text(alerted: dict[str, dt.datetime]) -> str:
    if set(alerted) == {"gateway"}:
        return "Hermes is back: the gateway answers."
    if set(alerted) == {"heartbeat"}:
        return "Hermes is back: the failure collector is reporting again."
    return ("Hermes is back: the failure collector is reporting again and the "
            "gateway answers.")


def write_state(alerted: dict[str, dt.datetime], streak: int, current: dt.datetime,
                grace_spent_for: str | None) -> bool:
    payload = {"checked_at": current.isoformat(),
               "alerted": {k: v.isoformat() for k, v in alerted.items()},
               "healthy_streak": streak}
    if grace_spent_for:
        payload["grace_spent_for"] = grace_spent_for
    return save_state(payload)


def main() -> int:
    global WARMUP_MINUTES
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--max-age-minutes", type=float, default=WARMUP_MINUTES)
    ap.add_argument("--health-url", default=HEALTH_URL)
    ap.add_argument("--repeat-hours", type=float, default=6.0)
    ap.add_argument("--skip-heartbeat", action="store_true")
    ap.add_argument("--skip-health", action="store_true")
    args = ap.parse_args()
    if args.skip_heartbeat and args.skip_health:
        # Both signals off reads as "always healthy", which could clear a real
        # alert and announce a recovery nothing verified. Refuse.
        print("refusing to skip both signals", file=sys.stderr)
        return 4
    WARMUP_MINUTES = args.max_age_minutes

    state = load_json(STATE)
    # Unknown ledger keys can never be evaluated, so they would block a recovery
    # announcement forever; the ledger only ever holds the two real signals.
    alerted = {k: v for k, v in clean_alerted(state.get("alerted")).items()
               if k in KNOWN_KINDS}
    raw_streak = state.get("healthy_streak")
    streak = raw_streak if isinstance(raw_streak, int) and not isinstance(raw_streak, bool) else 0
    stored_grace = state.get("grace_spent_for") if isinstance(state.get("grace_spent_for"), str) else None
    current = now()

    problems: dict[str, str] = {}
    evaluated: set[str] = set()
    suppressed = False
    grace_used = None
    if not args.skip_heartbeat:
        evaluated.add("heartbeat")
        found, suppressed, grace_used = heartbeat_problem(state)
        if found:
            problems["heartbeat"] = found
    if not args.skip_health:
        evaluated.add("gateway")
        found_gw = gateway_problem(args.health_url)
        if found_gw:
            problems["gateway"] = found_gw

    # The recovery decision needs the alert set as it stood *before* anything is
    # pruned: pruning first would empty the very set the announcement reports on.
    was_alerting = dict(alerted)

    # Prune only what this run actually checked and found healthy. A forgiven
    # heartbeat tick is no evidence that anything is fine, so it prunes nothing;
    # an unchecked signal keeps its alert.
    healthy_kinds = evaluated - set(problems)
    if not suppressed:
        for kind in list(alerted):
            if kind in healthy_kinds:
                del alerted[kind]

    # A fresh heartbeat re-arms the grace; a suppressed tick spends it.
    if suppressed and grace_used:
        next_grace = grace_used
    elif "heartbeat" in evaluated and not suppressed and "heartbeat" not in problems:
        next_grace = None
    else:
        next_grace = stored_grace

    if not problems:
        healthy_tick = not suppressed
        streak = streak + 1 if healthy_tick else 0
        # Recovery pending: everything is healthy, an alert is still open, and
        # every open kind was actually checked. The ledger is held until the
        # message goes out, or the announcement has nothing left to report on.
        pending = healthy_tick and bool(was_alerting) and set(was_alerting) <= evaluated
        if pending and streak >= RECOVERY_STREAK:
            if not send(recovery_text(was_alerting), args.dry_run):
                # Keep the alert set so the next tick retries the news, and keep
                # the spent grace so it is not forgiven a second time.
                if not args.dry_run and not write_state(was_alerting, streak, current, next_grace):
                    return 3
                return 2
            alerted = {}
            streak = 0
        elif pending:
            alerted = dict(was_alerting)
        if not args.dry_run and not write_state(alerted, streak, current, next_grace):
            return 3
        return 0

    streak = 0
    window = args.repeat_hours * 3600
    due: list[str] = []
    for kind in problems:
        last = alerted.get(kind)
        if last is None:
            due.append(kind)
            continue
        elapsed = (current - last).total_seconds()
        # A stored timestamp in the future (a backwards clock step) counts as
        # due: suppressing on it would hide the problem until the clock caught up.
        if elapsed < 0 or elapsed >= window:
            due.append(kind)

    if due:
        text = "Hermes check: " + "; ".join(problems[kind] for kind in due)
        if not send(text, args.dry_run):
            # Nothing is recorded as sent, so the next tick tries again -- but a
            # grace spent this tick stays spent, so one outage buys one silence.
            if not args.dry_run:
                write_state(alerted, streak, current, next_grace)
            return 2
        for kind in due:
            alerted[kind] = current

    if args.dry_run:
        return 0
    if not write_state(alerted, streak, current, next_grace):
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
