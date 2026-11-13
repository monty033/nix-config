#!/usr/bin/env python3
"""oc-tier: resolve a work tier to a model from the routing roster, then create.

The roster is the only place model ids live. This helper never picks a model by
judgement: it takes a tier, walks that tier's candidates in order, and either
finds one that the live catalogue confirms and whose subscription windows are not
spent, or stops and says why. A roster entry may declare `extra_usage_until`, which
lets a window the collector reports as *spent* still route while the account has
paid extra usage behind it; it never lifts a window that is only flagged by the
provider while allowance remains, because extra usage does not clear a throttle.

stdout carries the session id and nothing else, so `SID=$(oc-tier create ...)`
works. Everything a human reads - the announcement, every skip, every refusal -
goes to stderr.

Usage:
  oc-tier list [TIER]
  oc-tier lint
  oc-tier pick TIER [--private] [--exclude ID]
  oc-tier create --tier T --dir D --title X (--plan STEP | --reason R)
                 [--agent build|plan] [--private] [--exclude ID]
                 [--new-reason S]

Exit codes: 0 ok, 2 usage or config error, 3 tier exhausted.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import subprocess
import sys
import time
import tomllib
from pathlib import Path

HERMES_HOME = Path(os.environ.get("HERMES_HOME", "/var/lib/hermes/.hermes"))

# The roster is two layers. The base inventory is declared in nix-config and
# installed read-only at ROSTER_BASE, so a fresh host dispatches correctly with
# nothing hand-placed. The local overlay at ROSTER_LOCAL adds candidates and
# overrides base entries by id, so a route that dies on a Tuesday morning is a
# file edit rather than a rebuild.
ROSTER_BASE = Path(os.environ.get("OC_TIER_ROSTER_BASE", "/etc/hermes/routing/models"))
ROSTER_LOCAL = Path(os.environ.get("OC_TIER_ROSTER_LOCAL", str(HERMES_HOME / "routing" / "models")))
OPENCODE_API = os.environ.get("OC_TIER_API", "/run/current-system/sw/bin/opencode-api")
QUOTA = Path(os.environ.get("OC_TIER_QUOTA", str(HERMES_HOME / "scripts" / "provider-quota" / "provider-quota.sh")))
FREE_SNAPSHOTS = Path(os.environ.get("OC_TIER_FREE_SNAPSHOTS", str(HERMES_HOME / "free-model-snapshots")))

WORK_TIERS = ("mechanical", "slice", "cross_module", "security", "plan")
TIERS = WORK_TIERS + ("review",)

# Provider prefix -> quota collector key. Anything else has no subscription window.
QUOTA_KEYS = {
    "claude-code": "claude-pro",
    "opencode-go": "opencode-go",
    "minimax-coding-plan": "minimax",
}
# The collector's JSON names differ from its CLI keys.
QUOTA_JSON_KEYS = {"claude-pro": "claude", "opencode-go": "opencodeGo", "minimax": "minimax"}

ROUTE_LABELS = {
    "claude-code": "Claude subscription",
    "minimax-coding-plan": "MiniMax plan",
    "opencode-go": "OpenCode Go",
    "opencode": "OpenCode Zen",
    "openrouter": "OpenRouter",
}

# A subscription-backed model must not run on a provider that bills OpenCode instead.
SUBSCRIPTION_ONLY = {"claude": "claude-code"}

QUOTA_FLOOR_PERCENT = 10
STALE_AFTER_DAYS = 30


class RosterError(RuntimeError):
    pass


def provider_of(model_id: str) -> str:
    return model_id.split("/", 1)[0] if "/" in model_id else ""


def _read_layer(directory: Path, source: str, required: bool = True) -> list[dict]:
    if not directory.is_dir():
        if required:
            raise RosterError(f"{source} layer missing: {directory} is not a directory")
        return []
    entries = []
    seen: dict[str, str] = {}
    seen_positions: dict[tuple[str, int], str] = {}
    for path in sorted(directory.glob("*.toml")):
        try:
            with open(path, "rb") as handle:
                data = tomllib.load(handle)
        except (OSError, tomllib.TOMLDecodeError) as error:
            raise RosterError(f"{source}/{path.name}: unreadable TOML ({error})") from None
        if not isinstance(data.get("id"), str):
            raise RosterError(f"{source}/{path.name}: no string id")
        data.setdefault("variant", "")
        data.setdefault("tiers", {})
        data.setdefault("free", False)
        data.setdefault("off", "")
        data.setdefault("why", "")
        data.setdefault("checked", "")
        if data["id"] in seen:
            raise RosterError(f"{source}: {path.name} and {seen[data['id']]} both declare {data['id']}; "
                              "one id, one file per layer")
        seen[data["id"]] = path.name
        tier = data["tiers"]
        if isinstance(tier, dict):
            for name, position in tier.items():
                if isinstance(position, int) and not isinstance(position, bool):
                    if (name, position) in seen_positions:
                        raise RosterError(f"{source}: {path.name} and {seen_positions[(name, position)]} both use "
                                          f"tier {name} position {position}")
                    seen_positions[(name, position)] = path.name
        data["_file"] = f"{source}/{path.name}"
        data["_source"] = source
        entries.append(data)
    return entries


def load_roster() -> list[dict]:
    """Base inventory, then the local overlay. A local entry replaces a base entry whole.

    Whole-file replacement, not field merging, because a half-merged entry is the
    kind of thing that looks right in review and dispatches something nobody wrote.
    """
    base = _read_layer(ROSTER_BASE, "base")
    local = _read_layer(ROSTER_LOCAL, "local", required=False)
    if not base and not local:
        raise RosterError(f"no roster found: checked {ROSTER_BASE} and {ROSTER_LOCAL}")

    if not base:
        raise RosterError(f"base layer is empty: {ROSTER_BASE} has no .toml files; the Nix-owned inventory is "
                          "not installed, so this is a broken install rather than a fallback")
    merged: dict[str, dict] = {entry["id"]: entry for entry in base}
    for entry in local:
        already = entry["id"] in merged
        entry["_source"] = "local (overrides base)" if already else "local"
        merged[entry["id"]] = entry
    entries = list(merged.values())
    if not entries:
        raise RosterError(f"roster is empty: {ROSTER_BASE} and {ROSTER_LOCAL}")
    return entries


def catalogue(attempts: int = 3) -> dict[str, list[str]]:
    """id -> advertised variants, from the live server.

    An empty or unparseable response is never a real catalogue, so it is retried
    rather than reported: telling a caller the catalogue is empty would look like
    every route in the roster had died at once.
    """
    last = ""
    for attempt in range(attempts):
        if attempt:
            time.sleep(1.5)
        try:
            result = subprocess.run([OPENCODE_API, "models"], capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.SubprocessError) as error:
            last = f"could not read the catalogue: {error}"
            continue
        if result.returncode != 0:
            last = "opencode-api models failed"
            continue
        found: dict[str, list[str]] = {}
        for line in result.stdout.splitlines():
            parts = line.split("\t")
            if not parts or "/" not in parts[0]:
                continue
            variants = [v for v in (parts[1].strip() if len(parts) > 1 else "").split(",") if v and v != "unknown"]
            found[parts[0].strip()] = variants
        if found:
            return found
        last = "live catalogue was empty"
    raise RosterError(f"{last} (after {attempts} attempts)")


def catalogue_for(entries: list[dict]) -> dict[str, list[str]]:
    """The live catalogue, re-read once when a roster id looks missing.

    A transient partial response must not be reported as a dead route: that would
    skip a working candidate, or exhaust a tier, on a measurement glitch.
    """
    live = catalogue()
    if any(entry["id"] not in live for entry in entries):
        try:
            second = catalogue()
        except RosterError:
            return live
        for model_id, variants in second.items():
            live.setdefault(model_id, variants)
    return live


def validate_structure(entries: list[dict]) -> list[str]:
    """Roster problems that are wrong whatever the live server currently says.

    These block dispatch: a malformed or contradictory file is a mistake, not a
    route death. Live-state checks belong in validate_live, because a dead route
    must produce a skip in resolve() rather than an outage for every tier.
    """
    problems: list[str] = []

    for entry in entries:
        name, model_id = entry["_file"], entry["id"]

        tiers = entry["tiers"]
        if not isinstance(tiers, dict):
            problems.append(f"{name}: tiers must be a table")
            continue
        work = [t for t in tiers if t in WORK_TIERS]
        if len(work) != 1 and not (not work and "review" in tiers):
            problems.append(f"{name}: {len(work)} work tiers, expected exactly one, or review alone")
        if not tiers:
            problems.append(f"{name}: no tiers at all")
        for tier, position in tiers.items():
            if tier not in TIERS:
                problems.append(f"{name}: unknown tier {tier!r}")
                continue
            if not isinstance(position, int) or isinstance(position, bool) or position < 1:
                problems.append(f"{name}: tier {tier} position must be a positive integer")
                continue
            # A position may be shared across layers on purpose: that is how a
            # local entry inserts a candidate ahead of a base one. Within a single
            # layer it stays an error, detected in _read_layer.
        if work == ["mechanical"] and entry["free"] is not True:
            problems.append(f"{name}: mechanical candidates must be free = true")

        if not isinstance(entry["free"], bool):
            problems.append(f"{name}: free must be true or false, not {entry['free']!r}")
        if not isinstance(entry["variant"], str):
            problems.append(f"{name}: variant must be a string")
        if not isinstance(entry["off"], str):
            problems.append(f"{name}: off must be a string")

        provider = provider_of(model_id)
        if provider not in ROUTE_LABELS:
            problems.append(f"{name}: provider {provider!r} is not a known route")
        for needle, required in SUBSCRIPTION_ONLY.items():
            if needle in model_id.lower() and provider != required:
                problems.append(f"{name}: {needle} model must use the {required}/ route, not {provider}/")

        if (model_id.endswith("-free") or ":free" in model_id) and not entry["free"]:
            problems.append(f"{name}: free-suffix id marked free=false")

        if not entry["why"]:
            problems.append(f"{name}: empty why")
        try:
            datetime.date.fromisoformat(str(entry["checked"]))
        except ValueError:
            problems.append(f"{name}: checked must be an ISO date, not {entry['checked']!r}")
        # A date ahead of the host clock is a clock problem, not a roster problem:
        # it must not stop dispatch on a read-only base entry. lint warns instead.
        # Only an explicit date switches a spent window back on, and a date that
        # cannot be parsed is a mistake, not a route death: catch it here so it
        # never silently reads as "no extra usage" in resolve(). An *expired* date
        # is legal and expected, so it is a lint note, not a structural problem.
        declared = entry.get("extra_usage_until")
        if declared not in (None, "") and strict_date(declared) is None:
            problems.append(
                f"{name}: extra_usage_until must be a YYYY-MM-DD date, not {declared!r}")
    return problems


def validate_live(entries: list[dict], live: dict[str, list[str]]) -> list[str]:
    """Checks against the catalogue and the free snapshot. lint only.

    resolve() walks past these as skips, so they must never block dispatch.
    """
    problems: list[str] = []
    # One reader for the snapshot, so the diagnostic path announces a missing
    # audit exactly like the dispatch path instead of dying on it.
    free_ids = free_snapshot_ids()
    for entry in entries:
        name, model_id = entry["_file"], entry["id"]
        if model_id not in live:
            problems.append(f"{name}: id absent from the live catalogue")
        elif entry["variant"] and entry["variant"] not in live[model_id]:
            problems.append(f"{name}: variant {entry['variant']!r} not offered (has {live[model_id]})")
        elif not entry["variant"] and live[model_id]:
            problems.append(f"{name}: no variant set but route offers {live[model_id]}")
        if entry["free"] and model_id not in free_ids:
            problems.append(f"{name}: free=true but absent from the free-model audit")
    return problems


def validate(entries: list[dict], live: dict[str, list[str]]) -> list[str]:
    """Everything lint reports: structure first, then live state."""
    return validate_structure(entries) + validate_live(entries, live)


def free_snapshot_ids() -> set[str]:
    """Ids the daily free-model audit currently lists.

    Another probe: an unreadable snapshot set means less evidence, not a dead
    dispatcher, so it returns empty and the caller carries on with the flag and
    the id marker. Read once per invocation by the caller, not per candidate.
    """
    snapshots: list[Path] = []
    try:
        snapshots = sorted(FREE_SNAPSHOTS.glob("*.tsv"))
        text = snapshots[-1].read_text(encoding="utf-8", errors="replace") if snapshots else ""
    except OSError:
        text = ""
    if not text:
        # This probe decides whether a session gets a shell deny-list, so unlike
        # the quota probe it must say when it has no evidence: continuing quietly
        # would mean an unguarded session and no line about it.
        print(f"oc-tier: free-model audit has no readable snapshot under {FREE_SNAPSHOTS}; "
              "the deny-list decision rests on the declared flag and the model id alone", file=sys.stderr)
        return set()
    return {line.split("\t")[0].strip() for line in text.splitlines() if line.strip()}


def is_free(entry: dict, free_ids: set[str] | None = None) -> bool:
    """True on any positive evidence that this route is free.

    Evidence is the declared flag, a free-looking id, or membership in the free
    audit's snapshot. Absence of evidence means "treated as paid": a paid
    workhorse route must not get a shell deny-list, so this does not default to
    free. The consequence is that the guard rests on the flag, the id string, or
    the snapshot - an free route with no marker that the snapshot does not list
    is the residual case.
    """
    model_id = entry["id"]
    if entry.get("free") or model_id.endswith("-free") or ":free" in model_id:
        return True
    return model_id in (free_ids if free_ids is not None else free_snapshot_ids())


def candidates(entries: list[dict], tier: str) -> list[dict]:
    if tier not in TIERS:
        raise RosterError(f"unknown tier {tier!r}; expected one of {', '.join(TIERS)}")
    picked = []
    for entry in entries:
        tiers = entry.get("tiers")
        if not isinstance(tiers, dict) or tier not in tiers:
            continue
        position = tiers[tier]
        if not isinstance(position, int) or isinstance(position, bool):
            raise RosterError(f"{entry['_file']}: tier {tier} position must be an integer, not {position!r}")
        # A local entry may take a position the base already uses, so an overlay
        # can insert a candidate first instead of only appending. On a tie the
        # local entry wins the earlier slot.
        picked.append((position, 0 if entry.get("_source", "").startswith("local") else 1, entry))
    return [entry for _, _, entry in sorted(picked, key=lambda triple: (triple[0], triple[1]))]


def quota_snapshot(provider_key: str | None, cache: dict[str, dict | None] | None = None) -> dict | None:
    """Collector record for a provider, or None when there is nothing to read.

    A probe failure is never fatal: measurement trouble must not stop dispatch.
    """
    if not provider_key:
        return None
    if cache is not None and provider_key in cache:
        return cache[provider_key]
    try:
        result = subprocess.run(
            [str(QUOTA), "--provider", provider_key, "--json"],
            capture_output=True, text=True, timeout=60,
        )
        document = json.loads(result.stdout)
        record = document.get("providers", {}).get(QUOTA_JSON_KEYS.get(provider_key, provider_key))
        if not isinstance(record, dict):
            record = {"status": "unknown", "reason": "provider not in collector output"}
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError, AttributeError):
        record = {"status": "unknown", "reason": "collector unavailable"}
    if cache is not None:
        cache[provider_key] = record
    return record


def _percent(value) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value.strip())
        except ValueError:
            return None
    return None


def binding_window(record: dict | None) -> dict | None:
    windows = [w for w in (record or {}).get("windows", []) if isinstance(w, dict)]
    usable = [w for w in windows if _percent(w.get("remainingPercent")) is not None]
    if not usable:
        return None
    return min(usable, key=lambda w: _percent(w.get("remainingPercent")))


def strict_date(raw) -> datetime.date | None:
    """Parse an exact `YYYY-MM-DD` date, or None.

    `strptime` alone also accepts `2027-1-1`, so the shape is checked first: the
    error messages promise `YYYY-MM-DD`, and a parser that quietly takes more than
    the message allows is a promise the code does not keep.
    """
    text = str(raw)
    if len(text) != 10 or text[4] != "-" or text[7] != "-":
        return None
    try:
        return datetime.datetime.strptime(text, "%Y-%m-%d").date()
    except ValueError:
        return None


def _extra_usage_until(entry: dict | None) -> datetime.date | None:
    """The date through which this route may run on the account's paid extra usage.

    The collector reports the included allowance only; it cannot see whether the
    account has extra usage enabled, so a spent window is indistinguishable from a
    spent window with credits behind it. A declared end date is the operator's
    statement about their own account: it lets a spent window route through its
    declared date and refuses again the day after, so nobody has to remember to
    remove it. Strict `YYYY-MM-DD` only: `date.fromisoformat` also accepts
    compact and week forms, and an operator hand-typing a date deserves the plain
    format spelled out in the error rather than a lenient parse.
    """
    if not entry:
        return None
    return strict_date(entry.get("extra_usage_until"))


def quota_verdict(record: dict | None, entry: dict | None = None,
                  today: datetime.date | None = None) -> tuple[str, str]:
    """Return (verdict, human text). verdict is 'ok', 'n/a' or 'exhausted'.

    `entry` supplies an optional `extra_usage_until` declaration. It lifts a refusal
    only when the allowance is *spent*: a provider flag on a window that still has
    allowance is a different failure and stays refused, because paid extra usage does
    not clear a throttle. A window that is spent *and* flagged is lifted, because
    there the flag is a consequence of the spend. `today` exists so the expiry
    boundary is testable.
    """
    if record is None:
        return "n/a", "quota: n/a (no subscription window)"
    if record.get("status") != "ok":
        return "ok", f"quota: unknown ({record.get('reason', record.get('status', 'unreadable'))})"
    window = binding_window(record)
    if window is None:
        return "ok", "quota: unknown (no readable windows)"
    remaining = _percent(window.get("remainingPercent"))
    status = window.get("windowStatus")
    reset = window.get("resetAtEdt") or "unknown"
    text = f"quota: {window.get('name')} {remaining:g}% left, resets {reset}"
    spent = remaining is not None and remaining < QUOTA_FLOOR_PERCENT
    flagged = bool(status) and status != "ok"
    if spent or flagged:
        until = _extra_usage_until(entry)
        if spent and until is not None:
            if until >= (today or datetime.date.today()):
                return "ok", f"{text} — on extra usage declared until {until.isoformat()}"
            # Expiry is the likeliest reason a route "worked yesterday": say so
            # instead of reporting a bare spend, which reads like nothing changed.
            return "exhausted", f"{text} — extra usage declaration expired {until.isoformat()}"
        return "exhausted", text
    return "ok", text


def resolve(tier: str, entries: list[dict], live: dict[str, list[str]], private: bool = False,
            exclude: list[str] | None = None, free_ids: set[str] | None = None) -> dict:
    """Walk the tier's candidates and return the first usable one."""
    excluded = list(exclude or [])
    free_ids = free_snapshot_ids() if free_ids is None else free_ids
    steps: list[dict] = []
    ordered = candidates(entries, tier)
    cache: dict[str, dict | None] = {}

    for index, entry in enumerate(ordered, start=1):
        label = f"{tier} {index}/{len(ordered)} {entry['id']}"
        if entry.get("off"):
            steps.append({"id": entry["id"], "cause": "off", "detail": entry["off"], "label": label})
            continue
        if any(entry["id"] == model_id or model_id.startswith(entry["id"] + ":") for model_id in excluded):
            steps.append({"id": entry["id"], "cause": "excluded", "detail": "excluded by caller", "label": label})
            continue
        if private and is_free(entry, free_ids):
            steps.append({"id": entry["id"], "cause": "private", "detail": "free model refused", "label": label})
            continue
        if entry["id"] not in live:
            steps.append({"id": entry["id"], "cause": "absent", "detail": "not in live catalogue", "label": label})
            continue
        if entry["variant"] and entry["variant"] not in live[entry["id"]]:
            steps.append({"id": entry["id"], "cause": "variant", "detail": f"{entry['variant']!r} not offered", "label": label})
            continue
        verdict, text = quota_verdict(quota_snapshot(QUOTA_KEYS.get(provider_of(entry["id"])), cache), entry)
        if verdict == "exhausted":
            steps.append({"id": entry["id"], "cause": "quota", "detail": text, "label": label})
            continue
        return {"ok": True, "entry": entry, "index": index, "total": len(ordered), "quota": text, "steps": steps}
    return {"ok": False, "tier": tier, "steps": steps}


def finish(entry: dict, tier: str, index: int, total: int, quota: str, provenance: str) -> str:
    route = ROUTE_LABELS.get(provider_of(entry["id"]), provider_of(entry["id"]))
    source = entry.get("_source", "local")
    return (f"{entry['id']} via {route} (tier {tier}, candidate {index} of {total}; {source}{provenance})"
            f" — {quota}")


def print_steps(steps: list[dict]) -> None:
    for step in steps:
        print(f"skip {step['label']}: {step['cause']} — {step['detail']}", file=sys.stderr)


def snub(session_id: str, why: str) -> None:
    """Abandon a session that was announced as something it is not.

    opencode-api cannot delete a session, and interrupt is a no-op on one that was
    never prompted, so this cannot neutralise it. Say what is actually true: the
    session exists, is idle, and must not be prompted.
    """
    try:
        subprocess.run([OPENCODE_API, "interrupt", session_id], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        pass
    print(f"oc-tier: {session_id} exists and is idle, but {why}. Do not prompt it.", file=sys.stderr)


def cmd_list(args) -> int:
    entries = load_roster()
    live = catalogue_for(entries)
    problems = validate_structure(entries)
    for problem in problems:
        print(f"oc-tier: roster problem — {problem}", file=sys.stderr)
    for tier in ([args.tier] if args.tier else list(TIERS)):
        print(f"{tier}:")
        for index, entry in enumerate(candidates(entries, tier), start=1):
            state = "ok"
            if entry.get("off"):
                state = f"off ({entry['off']})"
            elif entry["id"] not in live:
                state = "absent from catalogue"
            elif entry["variant"] and entry["variant"] not in live[entry["id"]]:
                state = f"variant {entry['variant']!r} not offered"
            suffix = f":{entry['variant']}" if entry["variant"] else ""
            print(f"  {index}. {entry['id']}{suffix}  [{state}] — {entry['why']}")
    return 0 if not problems else 2


def cmd_lint(args) -> int:
    entries = load_roster()
    problems = validate(entries, catalogue_for(entries))
    for problem in problems:
        print(f"oc-tier lint: {problem}")
    today = datetime.date.today()
    for entry in entries:
        try:
            age = (today - datetime.date.fromisoformat(str(entry["checked"]))).days
        except ValueError:
            continue
        if age > STALE_AFTER_DAYS:
            print(f"oc-tier lint: {entry['_file']}: checked {age} days ago (stale, not fatal)")
        elif age < 0:
            print(f"oc-tier lint: {entry['_file']}: checked date is {abs(age)} days in the future (clock?)")
        # Only subscription-backed routes can be refused for a spent window, so an
        # expired declaration anywhere else is noise.
        declared = _extra_usage_until(entry) if provider_of(entry["id"]) in QUOTA_KEYS else None
        if declared is not None and declared < today:
            print(f"oc-tier lint: {entry['_file']}: extra usage declaration expired "
                  f"{declared.isoformat()}; a spent window on this route will refuse again "
                  f"(not fatal)")
    base = sum(1 for entry in entries if entry.get("_source") == "base")
    local = len(entries) - base
    print(f"oc-tier lint: {len(entries)} entries ({base} base, {local} local), {len(problems)} problem(s)")
    return 0 if not problems else 2


def cmd_pick(args) -> int:
    entries = load_roster()
    problems = validate_structure(entries)
    if problems:
        for problem in problems:
            print(f"oc-tier: roster problem — {problem}", file=sys.stderr)
        return 2
    result = resolve(args.tier, entries, catalogue_for(entries), private=args.private, exclude=args.exclude)
    print_steps(result["steps"])
    if not result["ok"]:
        print(f"oc-tier: tier {args.tier} exhausted — {len(result['steps'])} candidate(s) rejected. Not escalating.",
              file=sys.stderr)
        return 3
    entry = result["entry"]
    print(finish(entry, args.tier, result["index"], result["total"], result["quota"], ""))
    return 0


def cmd_create(args) -> int:
    entries = load_roster()
    live = catalogue_for(entries)
    problems = validate_structure(entries)
    if problems:
        for problem in problems:
            print(f"oc-tier: roster problem — {problem}", file=sys.stderr)
        return 2

    provenance = ""
    if args.plan:
        provenance += f"; plan {args.plan}"
    if args.reason:
        provenance += f"; own: {args.reason}"
    free_ids = free_snapshot_ids()
    result = resolve(args.tier, entries, live, private=args.private, exclude=args.exclude, free_ids=free_ids)
    print_steps(result["steps"])
    if not result["ok"]:
        print(f"oc-tier: tier {args.tier} exhausted — not escalating.", file=sys.stderr)
        return 3

    entry = result["entry"]
    announcement = finish(entry, args.tier, result["index"], result["total"], result["quota"], provenance)
    # A stale entry in this tier is a reason to distrust this dispatch; a stale
    # entry in some other tier is not.
    today = datetime.date.today()
    for candidate_entry in candidates(entries, args.tier):
        try:
            age = (today - datetime.date.fromisoformat(str(candidate_entry["checked"]))).days
        except ValueError:
            continue
        if age > STALE_AFTER_DAYS:
            print(f"oc-tier: {candidate_entry['id']} was last checked {age} days ago; the route may have moved",
                  file=sys.stderr)

    agent = args.agent or ("plan" if args.tier in ("plan", "review") else "build")
    title = f"{args.tier}/{args.plan}/{args.title}" if args.plan else f"{args.tier}/{args.title}"

    command = [
        OPENCODE_API, "create",
        "--dir", args.dir, "--title", title,
        "--model", entry["id"], "--reason", announcement,
        "--agent", agent,
    ]
    if entry["variant"]:
        command += ["--variant", entry["variant"]]
    if args.new_reason:
        command += ["--new-reason", args.new_reason]

    print(f"announce: {announcement}", file=sys.stderr)
    try:
        created = subprocess.run(command, capture_output=True, text=True, timeout=180)
    except subprocess.TimeoutExpired:
        print("oc-tier: create timed out after 180s. A session may exist in that directory; check with "
              f"`opencode-api sessions {args.dir}` before retrying.", file=sys.stderr)
        return 2
    ids = [line.strip() for line in (created.stdout or "").splitlines() if line.strip().startswith("ses_")]
    if created.returncode != 0 or not ids:
        print(f"oc-tier: create failed — {(created.stderr or '').strip()[:400]}", file=sys.stderr)
        return 2
    session_id = ids[-1]

    actual: dict = {}
    unreadable = ""
    try:
        info = subprocess.run([OPENCODE_API, "info", session_id], capture_output=True, text=True, timeout=60)
        actual = json.loads(info.stdout).get("model", {})
        if not isinstance(actual, dict) or not actual:
            unreadable = "info returned no model"
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        unreadable = f"info unreadable ({type(error).__name__})"
    if unreadable:
        snub(session_id, f"its model could not be confirmed: {unreadable}")
        return 2
    want_variant = entry["variant"]
    have_variant = actual.get("variant") or ""
    # A model that advertises no variants may report "", "default" or nothing.
    variant_ok = have_variant == want_variant or (want_variant == "" and have_variant in ("", "default"))
    pair_ok = (actual.get("providerID"), actual.get("id")) == (provider_of(entry["id"]), entry["id"].split("/", 1)[1])
    if not pair_ok or not variant_ok:
        want = f"{provider_of(entry['id'])}/{entry['id'].split('/', 1)[1]}" + (f":{want_variant}" if want_variant else "")
        snub(session_id, f"it reports {actual.get('providerID')}/{actual.get('id')}"
                         f":{actual.get('variant') or '-'} and the roster says {want}")
        return 2

    if is_free(entry, free_ids):
        # opencode-api attaches the deny-list itself for ids ending "-free", but
        # not for OpenRouter ":free" routes or for a free model declared free =
        # false, so attach unconditionally and treat a failure as a refusal rather
        # than leaving an unguarded session running.
        try:
            denied = subprocess.run([OPENCODE_API, "deny", session_id], capture_output=True, text=True, timeout=60)
            deny_ok = denied.returncode == 0
        except (OSError, subprocess.SubprocessError):
            deny_ok = False
        if not deny_ok:
            snub(session_id, "the free-model deny-list could not be attached, so it has no shell guard")
            return 2

    print(session_id)
    print(f"created {title} on {entry['id']}" + (f":{entry['variant']}" if entry["variant"] else "")
          + f" as {agent}; info ok" + ("; deny-list attached" if is_free(entry, free_ids) else ""), file=sys.stderr)
    return 0


def cmd_effort(args) -> int:
    """Raise or lower the effort of an existing session without changing its model.

    The criteria say raise effort before changing model or tier. The raw tool for
    that, `opencode-api switch`, takes any model id, which reopens the surface the
    roster exists to close: this pins the switch to the model already in use.
    """
    entries = load_roster()
    problems = validate_structure(entries)
    if problems:
        for problem in problems:
            print(f"oc-tier: roster problem — {problem}", file=sys.stderr)
        return 2
    try:
        info = subprocess.run([OPENCODE_API, "info", args.session], capture_output=True, text=True, timeout=60)
        session = json.loads(info.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        print(f"oc-tier: could not read {args.session}: {type(error).__name__}", file=sys.stderr)
        return 2
    model = session.get("model") or {}
    provider, model_id = model.get("providerID"), model.get("id")
    if not provider or not model_id:
        print(f"oc-tier: {args.session} has no model to keep", file=sys.stderr)
        return 2

    entry = next((e for e in entries if provider_of(e["id"]) == provider and e["id"].split("/", 1)[1] == model_id), None)
    if entry is None:
        print(f"oc-tier: {provider}/{model_id} is not in the roster, so effort cannot be adjusted through it. "
              "A model outside the roster is a question to Patrick, not a switch.", file=sys.stderr)
        return 2

    live = catalogue_for(entries)
    offered = live.get(entry["id"], [])
    if args.level not in offered:
        print(f"oc-tier: {entry['id']} offers {offered or 'no variants'}; {args.level!r} is not one of them",
              file=sys.stderr)
        return 2

    was = model.get("variant") or "-"
    if was == args.level:
        print(f"effort: {entry['id']} is already at {args.level}; nothing to change", file=sys.stderr)
        return 0
    switched = subprocess.run(
        [OPENCODE_API, "switch", args.session, entry["id"], args.level],
        capture_output=True, text=True, timeout=120,
    )
    if switched.returncode != 0:
        print(f"oc-tier: switch failed — {(switched.stderr or '').strip()[:300]}", file=sys.stderr)
        return 2

    try:
        after = json.loads(subprocess.run([OPENCODE_API, "info", args.session], capture_output=True,
                                          text=True, timeout=60).stdout).get("model", {})
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        after = {}
    if (after.get("providerID"), after.get("id"), after.get("variant")) != (provider, model_id, args.level):
        print(f"oc-tier: switch did not take — {args.session} reports {after}", file=sys.stderr)
        return 2

    route = ROUTE_LABELS.get(provider, provider)
    tiers = "/".join(sorted(entry["tiers"]))
    print(f"effort: {entry['id']} via {route} {was} -> {args.level} (same model, tier {tiers})", file=sys.stderr)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="oc-tier", description="Resolve a work tier from the routing roster.")
    sub = parser.add_subparsers(dest="command", required=True)

    listing = sub.add_parser("list", help="show candidates for one tier or all")
    listing.add_argument("tier", nargs="?", choices=TIERS)
    listing.set_defaults(func=cmd_list)

    lint = sub.add_parser("lint", help="check the roster against the live catalogue")
    lint.set_defaults(func=cmd_lint)

    pick = sub.add_parser("pick", help="dry run: show what would be chosen")
    pick.add_argument("tier", choices=TIERS)
    pick.add_argument("--private", action="store_true", help="refuse free candidates")
    pick.add_argument("--exclude", action="append", default=[], help="model id to skip (author's model)")
    pick.set_defaults(func=cmd_pick)

    effort = sub.add_parser("effort", help="change a session's effort, keeping its model")
    effort.add_argument("session")
    effort.add_argument("level", help="e.g. low, high, xhigh")
    effort.set_defaults(func=cmd_effort)

    create = sub.add_parser("create", help="create a session on the resolved candidate")
    create.add_argument("--tier", required=True, choices=TIERS)
    create.add_argument("--dir", required=True)
    create.add_argument("--title", required=True)
    create.add_argument("--plan", default="", help="plan step this dispatch serves")
    create.add_argument("--reason", default="", help="why this dispatch, when it is not from the plan")
    create.add_argument("--agent", default=None, choices=("build", "plan"))
    create.add_argument("--private", action="store_true")
    create.add_argument("--exclude", action="append", default=[])
    create.add_argument("--new-reason", dest="new_reason", default="")
    create.set_defaults(func=cmd_create)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "create" and not (args.plan or args.reason):
        print("oc-tier: one of --plan or --reason is required; an unannounced session is the failure this exists to stop",
              file=sys.stderr)
        return 2
    try:
        return args.func(args)
    except RosterError as error:
        print(f"oc-tier: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
