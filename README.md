# nix-config

Personal NixOS homelab configuration managing 37 flake configurations across Proxmox LXC containers, servers, laptops, templates, development systems, and installation images. The primary package set tracks NixOS 26.05, with additional unstable and pinned inputs where required.

## Prerequisites

- Nix with flakes enabled
- `just` for common local and remote operations
- Python 3 for the guarded PR workflow and its tests
- SOPS and an age key for editing encrypted secrets
- SSH and Tailscale access for remote builds and deployments
- Forgejo credentials configured through Git's credential helper for PR submission

## Structure

- [`flake.nix`](flake.nix) — entry point; inputs include home-manager, disko, sops-nix, plasma-manager, and Hermes Agent
- [`flake.lock`](flake.lock) — pinned input revisions; commits to PRs that bump inputs should call out the source/timestamp of the new commit
- `hosts/`
  - [`nxc/`](hosts/nxc) — Proxmox LXC containers (Jellyfin, Nextcloud, Forgejo, Paperless-NGX, Ollama, etc.); new containers are provisioned with [nxc-scripts](https://github.com/monty033/nxc-scripts)
    - `nxc/common/` — shared modules for LXC containers
  - [`nixbooks/`](hosts/nixbooks) — laptop configurations (ali-book, emma-book, cora-book)
  - individual servers such as [bifrost](hosts/bifrost), [tesseract](hosts/tesseract), and [yondu](hosts/yondu)
  - [`rescue/`](hosts/rescue), [`dev/`](hosts/dev) — installation image and development configurations
  - [`common/`](hosts/common) — shared host modules
- [`modules/`](modules) — reusable NixOS modules (auto-upgrade, Tailscale, Caddy proxy, mount helpers, host check-in)
- [`users/`](users) — home-manager user configurations (patrick, lina)
- [`ansible/`](ansible) — bootstrap playbooks for non-NixOS infrastructure
- [`secrets/`](secrets) — sops-nix encrypted secrets
- [`packages/`](packages) — custom package definitions
- [`scripts/`](scripts) — operational tooling, including the guarded `nix-pr` workflow
- [`tests/`](tests) — unit tests for repository tooling
- [`AGENT.md`](AGENT.md) — repository-specific guidance for automation agents
- [`justfile`](justfile) — task runner for common workflows

See [`host-states.md`](host-states.md) for the latest recorded operational snapshot. The flake remains authoritative for configured hosts.

## OpenCode v2 on Hermes

Hermes runs the pinned OpenCode v2 package (`2.0.23`) on its Tailscale address,
port `4096`. On Murdock, run `opencode-hermes` to launch the pinned TUI against
`http://hermes.skink-galaxy.ts.net:4096`; browser access uses
`https://opencode.montycasa.net` through Caddy TLS to the Hermes Tailscale
upstream. The local-proxy boundary is operator-confirmed LAN/Tailscale-only;
it was not independently live-verified.

`opencode-server.service` declaratively loads OpenChamber Claude (`@openchamber/opencode-claude` 1.3.7) and Goal (`opencode-goal-plugin` 1.2.0) from pinned Nix packages via `OPENCODE_CONFIG_CONTENT`. The Goal package is also in Murdock's profile: OpenCode v2 advertises its remote TUI component, and the local matching package makes that component available without a runtime npm fetch. Claude's Agent SDK integration requires the Claude Code CLI on the Hermes service PATH; authentication remains the user's normal Claude CLI state. Review Goal's `verify-cmd` configuration before use: it runs a command to verify goal completion.

The SOPS EnvironmentFile secret `opencode-server-env` must contain a
non-empty `OPENCODE_SERVER_PASSWORD=...` assignment; keep its value out of Nix
and the store. Rotating it requires updating that secret; sops-nix restarts
`opencode-server.service` when the rendered file changes.
`scripts/update-opencode-v2.sh VERSION` previews the package version and hash
diff only; it does not edit files. For rollback, revert the package
version/hash change and rebuild/switch through the normal reviewed deployment
workflow; do not change proxy or firewall rules as part of an OpenCode rollback.

## NookBridge settings

NookBridge settings can be declared inline in Nix or supplied as a separate
JSON file. Both forms produce the same root-owned,
`/etc/nookbridge/settings.json` payload and restart `nookd` when the content
changes. Configure exactly one source:

```nix
extra-services.nookbridge = {
  enable = true;
  settingsFile = null;
  settings = {
    defaults = {
      read = true;
      edit = true;
      create = false;
      delete = false;
    };
    overrides = [
      { notebooks = [ "Financial" ]; delete = false; }
      { notes = [ "private/**" ]; edit = false; }
    ];
  };
};
```

For a separate declarative JSON file, leave `settings` as `null` and set
`settingsFile` to a Nix path:

```nix
extra-services.nookbridge = {
  settings = null;
  settingsFile = ./nookbridge/settings.json;
};
```

The JSON file uses version `1` with `defaults` and `overrides` fields. It is
copied into the Nix store and installed as `root:root` mode `0640`; it is not a
runtime-editable file. Keep settings limited to non-secret permission policy:
Nix-store copies are readable to local users according to normal store
permissions. `nookd` validates either form fail-closed before it constructs the
Notesnook runtime. CLI-managed, non-Nix installations continue
to use their separate user settings file through `nookctl settings edit`.

## Common Commands

```bash
just nrs                     # switch the local running system
just nrs-r HOST              # switch a remote running system
just nrsb-r HOST             # build remotely, then switch the target
just nfc                     # run nix flake check
just secrets                 # edit sops-encrypted secrets
just rescue-build            # build rescue ISO
just ap HOST                 # run ansible playbook against a host
```

The `nrs`, `nrs-r`, and `nrsb-r` commands modify running systems. Verify the target host and rollback access before a production switch. Pull-request submission and deployment are separate operations: `scripts/nix-pr submit` does not build, switch, merge, or deploy a system.

## Guarded PR workflow

The repository-local `scripts/nix-pr` wrapper owns branch safety, validation receipts, commit-message checks, and verified Forgejo PR submission. It does not edit Nix, deploy systems, merge PRs, or depend on an LLM.

Start a new task from a clean checkout, then stage and validate one logical change group:

```bash
scripts/nix-pr start <slug>
# edit normally
git add <intended-files>
scripts/nix-pr check [--second-review-file /path/to/review.txt]
scripts/nix-pr commit --message-file /path/to/commit-message.txt
scripts/nix-pr submit --dry-run
scripts/nix-pr submit
```

Use `scripts/nix-pr status` as the first troubleshooting command. Use `--host NAME` for a shared Nix change when the affected host cannot be inferred from its path, or `--all-hosts` when every flake configuration must be built. Production Nix and systemd changes require a saved independent read-only review of the exact staged diff, passed through `--second-review-file`; documentation-only changes do not. Use the configured review route unless the task explicitly names another reviewer. If the required reviewer is unavailable, stop rather than silently substituting another model. The wrapper verifies the review artifact and records its digest; model selection belongs to the workflow guidance, not the wrapper.

Validation receipts are stored outside the repository under the user's XDG state directory. Run the test suite with:

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

Commit messages must use imperative mood, omit trailing punctuation, and contain no `Co-Authored-By` or AI attribution. They must use this Markdown format so the PR description and future `git log` history remain useful:

```markdown
<scope>: <imperative summary>

## Summary

What changed and what result it provides.

## Why this matters

The problem, root cause, constraints, or design decision.

## Verification

- Exact parse, evaluation, build, test, or runtime checks

## Deployment / Post-merge checklist

Only when relevant: rebuilds, restarts, migrations, rollback steps, or
subscriber/user follow-up.
```

`## Summary` and `## Verification` must be populated. Substantive changes must provide at least 350 body characters. The wrapper validates this format before committing and again before submission.

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgments

- [Sascha Koenig YouTube Playlist](https://www.youtube.com/playlist?list=PLCQqUlIAw2cCuc3gRV9jIBGHeekVyBUnC)
- [Sascha Koenig Repository](https://code.m3ta.dev/m3tam3re/nixcfg)
