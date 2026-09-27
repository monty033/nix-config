# Agent Instructions

## Commit Workflow

When asked to review and commit changes in this repository:

1. Use `scripts/nix-pr status` to inspect repository and validation state.
2. For a new task, start from a clean checkout with `scripts/nix-pr start <slug>`.
3. Run `git diff` and `git status` to identify all changes.
4. Group changes by logical concern and stage only the intended files for one group.
5. Run `scripts/nix-pr check`; for production Nix or systemd changes, first obtain a saved independent read-only review of the exact staged diff and pass it with `--second-review-file`. Use the configured review route unless the task explicitly names another reviewer. If the required reviewer is unavailable, stop rather than silently substituting another model.
6. Create the commit with `scripts/nix-pr commit --message-file <path>`.
7. Submit only when authorized, using `scripts/nix-pr submit`; use `--dry-run` first when appropriate.

The wrapper owns validation receipts, commit-message checks, pushing, and verified Forgejo PR creation. It does not edit files, merge PRs, deploy systems, resolve conflicts, or force-push.

Commit messages must use imperative mood, omit trailing punctuation, and contain no `Co-Authored-By` or AI attribution. For every committed change, use the historical Markdown format that makes the commit useful to a future agent reading `git log`:

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

`## Summary` and `## Verification` must be populated. Substantive changes must provide at least 350 body characters; add the relevant optional sections rather than compressing operational context into one paragraph. `scripts/nix-pr` validates this format before committing and again before submission.

## Host Access

Hosts are defined as directories under `hosts/` (excluding `common`, which contains shared modules). This includes subdirectories of `hosts/nxc/` (also excluding `nxc/common`), which are LXC containers. Each host can be reached over Tailscale via `ssh root@<hostname>`, where `<hostname>` is the directory name. Before SSHing, run `hostname` to check if the target host is the local machine — if it matches, run commands directly instead.
