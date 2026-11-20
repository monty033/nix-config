#!/usr/bin/env python3
"""Publish the owner's Signal chat ids into the Hermes admin config layer.

Why this exists
---------------
Hermes has no per-platform model default. The only supported way to give one
conversation its own route is ``platforms.<name>.channel_overrides``, keyed by
the literal chat id, and a YAML key is not expanded from the environment. For a
Signal DM that key is the peer's account UUID -- the same value the DM allowlist
holds. This repository is published to GitHub, so the id must not appear in it:
it stays in the encrypted environment file and this unit republishes it into the
admin scope (``/etc/hermes/config.yaml``), which is generated on the host and
never committed.

The admin scope is deep-merged over the user config with managed values winning
at the leaf, so the entry here overrides the route for that conversation and
touches nothing else.

Ownership and limits
--------------------
This unit treats ``/etc/hermes/config.yaml`` as its own file and rewrites it
wholesale from its parsed form, so comments, key order, anchors and quoting in an
existing file do not survive: a hand-maintained file is reformatted the first
time this runs. Its keys survive as data. Ids are only ever added; removing an id
from the allowlist leaves its (then unreachable) override in place, because a
stale entry for a disallowed id is inert and choosing a pruning policy is not
this script's call. It assumes a single writer -- two would be last-writer-wins.
A new file is owned by root and grouped to the gateway user's primary group; an
existing file keeps its own owner and mode. Either way the resulting permissions
are reported, and a file the gateway cannot read produces a warning, because that
is the failure mode where the unit is green and the route is silently inert.

Route validation
----------------
The gateway resolves a channel override's provider WITHOUT a fallback: unlike a
session ``/model`` switch, an unresolvable provider raises while the turn is being
prepared, so a typo here would fail every Signal turn instead of falling through
to the global chain. The script therefore refuses to write a provider the live
user config never references, and warns when the exact model/provider pair is
unfamiliar. That is a typo guard, not proof the route is servable -- servability
is proven by a live probe when the route changes.

Environment
-----------
``SIGNAL_ALLOWED_USERS``   required; comma or whitespace separated chat ids.
``SIGNAL_MODEL``           the route's model id (set by the unit).
``SIGNAL_PROVIDER``        the route's provider slug (set by the unit).

Exit codes
----------
0  written, or already current
2  no usable id in the environment (nothing written)
3  an id is not a UUID, or a file is unparseable / shaped unexpectedly
4  the write failed
5  the environment is incomplete or unsafe (no route, unknown provider, no group)
"""

from __future__ import annotations

import os
import re
import stat
import sys
import tempfile
import time
from pathlib import Path

import yaml

TARGET = Path("/etc/hermes/config.yaml")
USER_CONFIG = Path("/var/lib/hermes/.hermes/config.yaml")
NEW_FILE_MODE = 0o640
GATEWAY_USER = "hermes"
TEMP_PREFIX = ".config.yaml."
STALE_TEMP_SECONDS = 3600

UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)


def chat_ids(raw: str) -> list[str]:
    """Ids from the allowlist value, de-duplicated, in their original order.

    UUIDs are case-insensitive but the gateway's chat id is the lowercase form, and
    an override keyed with an uppercase UUID never matches -- so keys are lowercased.
    """
    seen: dict[str, None] = {}
    for token in re.split(r"[,\s]+", raw.strip()):
        key = token.lower()
        if key and key not in seen:
            seen[key] = None
    return list(seen)


def referenced_providers(config: dict) -> set[str]:
    """Every provider slug the user config names, wherever it names one."""
    found: set[str] = set()

    def add_pair(value) -> None:
        if isinstance(value, str) and "/" in value:
            found.add(value.split("/", 1)[0])

    model_cfg = config.get("model")
    if isinstance(model_cfg, dict):
        provider = model_cfg.get("provider")
        if isinstance(provider, str):
            found.add(provider)
        aliases = model_cfg.get("aliases")
        if isinstance(aliases, dict):
            for value in aliases.values():
                add_pair(value)
    elif isinstance(model_cfg, str):
        add_pair(model_cfg)

    fallbacks = config.get("fallback_providers")
    if isinstance(fallbacks, list):
        for entry in fallbacks:
            if isinstance(entry, dict) and isinstance(entry.get("provider"), str):
                found.add(entry["provider"])

    for section in ("auxiliary", "delegation"):
        block = config.get(section)
        if not isinstance(block, dict):
            continue
        provider = block.get("provider")
        if isinstance(provider, str):
            found.add(provider)
        for value in block.values():
            if isinstance(value, dict) and isinstance(value.get("provider"), str):
                found.add(value["provider"])

    found.discard("")
    return found


def known_routes(config: dict) -> set[str]:
    """``provider/model`` pairs the user config names explicitly."""
    pairs: set[str] = set()

    model_cfg = config.get("model")
    if isinstance(model_cfg, dict):
        primary = model_cfg.get("default") or model_cfg.get("model")
        provider = model_cfg.get("provider")
        if isinstance(primary, str) and "/" in primary:
            pairs.add(primary)
        elif isinstance(primary, str) and isinstance(provider, str) and provider:
            pairs.add(f"{provider}/{primary}")
        aliases = model_cfg.get("aliases")
        if isinstance(aliases, dict):
            for value in aliases.values():
                if isinstance(value, str) and "/" in value:
                    pairs.add(value)

    fallbacks = config.get("fallback_providers")
    if isinstance(fallbacks, list):
        for entry in fallbacks:
            if isinstance(entry, dict):
                provider, model = entry.get("provider"), entry.get("model")
                if isinstance(provider, str) and isinstance(model, str):
                    pairs.add(f"{provider}/{model}")

    delegation = config.get("delegation")
    if isinstance(delegation, dict):
        provider, model = delegation.get("provider"), delegation.get("model")
        if isinstance(provider, str) and isinstance(model, str):
            pairs.add(f"{provider}/{model}")

    return pairs


def read_yaml(path: Path, label: str):
    """Parsed mapping at *path*, or None when absent; exit 3 when unusable."""
    if not path.exists():
        return None
    try:
        loaded = yaml.safe_load(path.read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"signal-managed-scope: cannot parse {label} ({exc})", file=sys.stderr)
        sys.exit(3)
    if loaded is None:  # empty document
        loaded = {}
    if not isinstance(loaded, dict):
        print(f"signal-managed-scope: {label} is not a mapping", file=sys.stderr)
        sys.exit(3)
    return loaded


def child_mapping(parent: dict, key: str, label: str) -> dict:
    """``parent[key]`` as a mapping, created when absent; a null counts as empty."""
    value = parent.get(key)
    if value is None:
        value = {}
        parent[key] = value
    if not isinstance(value, dict):
        print(f"signal-managed-scope: {label} is not a mapping", file=sys.stderr)
        sys.exit(3)
    return value


def clean_stale_temps(parent: Path) -> None:
    """Remove temp files a killed run left behind, before they are group-readable."""
    cutoff = time.time() - STALE_TEMP_SECONDS
    try:
        candidates = list(parent.glob(TEMP_PREFIX + "*"))
    except OSError:
        return
    for stale in candidates:
        try:
            if stale.stat().st_mtime < cutoff:
                stale.unlink()
        except OSError:
            continue


def report_access(verbose: bool) -> None:
    """Say who can read the admin file, and warn when the gateway cannot.

    The gateway runs as GATEWAY_USER, so a file whose owner or group is not that
    account is inert even though this unit succeeded. Checked on the no-op path as
    well, because a file written once keeps its permissions across boots.
    """
    try:
        st = TARGET.stat()
    except OSError:
        return
    mode = stat.S_IMODE(st.st_mode)
    if verbose:
        print(
            f"signal-managed-scope: {TARGET} is mode {oct(mode)}, "
            f"owner {st.st_uid}, group {st.st_gid}"
        )
    try:
        import pwd

        gateway = pwd.getpwnam(GATEWAY_USER)
    except Exception:
        return
    readable = (
        (st.st_uid == gateway.pw_uid and mode & 0o400)
        or (st.st_gid == gateway.pw_gid and mode & 0o040)
        or mode & 0o004
    )
    if not readable:
        print(
            f"signal-managed-scope: warning: {TARGET} (mode {oct(mode)}, owner "
            f"{st.st_uid}, group {st.st_gid}) is not readable by {GATEWAY_USER} "
            f"(uid {gateway.pw_uid}, gid {gateway.pw_gid}), so the gateway will not "
            "apply this admin layer",
            file=sys.stderr,
        )


def main() -> int:
    global TARGET
    # A symlinked admin file (dotfiles, or a future /etc/static indirection) is
    # written through to its target: os.replace would otherwise leave a regular
    # file where the next activation reinstates the link, silently losing the route.
    if TARGET.is_symlink():
        TARGET = TARGET.resolve()

    raw = os.environ.get("SIGNAL_ALLOWED_USERS", "")
    ids = chat_ids(raw)
    if not ids:
        print(
            "signal-managed-scope: SIGNAL_ALLOWED_USERS is empty; "
            "the Signal route override was not written",
            file=sys.stderr,
        )
        return 2

    bad = [i for i in ids if not UUID_RE.match(i)]
    if bad:
        ids = [i for i in ids if UUID_RE.match(i)]
        print(
            f"signal-managed-scope: warning: {len(bad)} allowlist entr"
            f"{'y is' if len(bad) == 1 else 'ies are'} not a Signal UUID and "
            f"{'was' if len(bad) == 1 else 'were'} skipped"
            + ("" if ids else "; no usable id remains, so nothing was written"),
            file=sys.stderr,
        )
        if not ids:
            return 3

    model = os.environ.get("SIGNAL_MODEL", "").strip()
    provider = os.environ.get("SIGNAL_PROVIDER", "").strip()
    if not model or not provider:
        print(
            "signal-managed-scope: SIGNAL_MODEL and SIGNAL_PROVIDER must both be set; "
            "nothing was written",
            file=sys.stderr,
        )
        return 5
    if "/" in model:
        print(
            "signal-managed-scope: SIGNAL_MODEL must be a bare model id, not a "
            "provider/model pair; nothing was written",
            file=sys.stderr,
        )
        return 5

    user_config = read_yaml(USER_CONFIG, str(USER_CONFIG))
    if user_config is None:
        print(
            f"signal-managed-scope: {USER_CONFIG} is missing, so the route cannot be "
            "checked; an unchecked provider would fail every Signal turn instead of "
            "falling back, so nothing was written",
            file=sys.stderr,
        )
        return 5
    providers = referenced_providers(user_config)
    if not providers:
        print(
            f"signal-managed-scope: {USER_CONFIG} names no provider, so the route "
            "cannot be checked; nothing was written",
            file=sys.stderr,
        )
        return 5
    if provider not in providers:
        print(
            f"signal-managed-scope: provider '{provider}' is not referenced by "
            f"{USER_CONFIG}; the gateway would fail every Signal turn instead of "
            "falling back, so nothing was written",
            file=sys.stderr,
        )
        return 5
    if f"{provider}/{model}" not in known_routes(user_config):
        print(
            f"signal-managed-scope: warning: {provider}/{model} is not an alias, "
            "fallback entry or delegation route in the user config; verify it "
            "answers before relying on it",
            file=sys.stderr,
        )

    existing = read_yaml(TARGET, str(TARGET)) or {}
    platforms = child_mapping(existing, "platforms", "platforms")
    signal_block = child_mapping(platforms, "signal", "platforms.signal")
    overrides = child_mapping(signal_block, "channel_overrides", "channel_overrides")
    for chat_id in ids:
        overrides[chat_id] = {"model": model, "provider": provider}

    try:
        text = yaml.safe_dump(existing, sort_keys=True, default_flow_style=False)
    except Exception as exc:  # mixed-type keys or a non-representable value
        print(
            f"signal-managed-scope: cannot serialise the admin config ({exc})",
            file=sys.stderr,
        )
        return 3

    # Remove leftovers from a killed run even on the early "already current" path,
    # so a temp file that was chmodded group-readable does not linger.
    clean_stale_temps(TARGET.parent)

    if TARGET.exists():
        try:
            if TARGET.read_text(encoding="utf-8") == text:
                print(f"signal-managed-scope: {len(ids)} override(s) already current")
                report_access(verbose=False)
                return 0
        except OSError as exc:
            print(f"signal-managed-scope: cannot read {TARGET} ({exc})", file=sys.stderr)
            return 3

    # An existing file keeps its own owner and mode: this script adds two keys and
    # has no business widening who may read whatever else an operator put there. A
    # new file is root-owned and group-readable, because the gateway runs as hermes.
    if TARGET.exists():
        try:
            st = TARGET.stat()
        except OSError as exc:
            print(f"signal-managed-scope: cannot stat {TARGET} ({exc})", file=sys.stderr)
            return 3
        mode, owner, group = stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid
    else:
        mode, owner, group = NEW_FILE_MODE, 0, -1
        if os.geteuid() == 0:
            try:
                import grp
                import pwd

                gateway = pwd.getpwnam(GATEWAY_USER)
                group = gateway.pw_gid
            except Exception as exc:
                print(
                    f"signal-managed-scope: cannot resolve user '{GATEWAY_USER}' "
                    f"({exc}); refusing to ship a file the gateway could not read",
                    file=sys.stderr,
                )
                return 5

    try:
        TARGET.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp_path = tempfile.mkstemp(dir=str(TARGET.parent), prefix=TEMP_PREFIX)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(text)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(tmp_path, mode)
            if os.geteuid() == 0 and owner >= 0 and group >= 0:
                os.chown(tmp_path, owner, group)
            os.replace(tmp_path, TARGET)
        except Exception:
            Path(tmp_path).unlink(missing_ok=True)
            raise
        # Persist the rename itself, not just the file's contents. The file has
        # already landed, so a failure here is a warning, not a failed write.
        try:
            dir_fd = os.open(str(TARGET.parent), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
        except OSError as exc:
            print(
                f"signal-managed-scope: warning: could not fsync {TARGET.parent} ({exc}); "
                "the file is written but a crash could revert the rename",
                file=sys.stderr,
            )
    except Exception as exc:
        print(f"signal-managed-scope: write failed ({exc})", file=sys.stderr)
        return 4

    try:
        st = TARGET.stat()
        written_mode, written_owner, written_group = (
            stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid,
        )
        print(
            f"signal-managed-scope: wrote {len(ids)} Signal override(s) to {TARGET} "
            f"({model} via {provider}); mode {oct(written_mode)}, owner {written_owner}, "
            f"group {written_group}"
        )
        report_access(verbose=False)
    except OSError:
        print(
            f"signal-managed-scope: wrote {len(ids)} Signal override(s) to {TARGET} "
            f"({model} via {provider})"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
