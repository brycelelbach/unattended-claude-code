# unattended-brev-agent-bootstrap

A single idempotent bash script that turns a fresh Linux host into a ready-to-use Claude Code agent environment. Built for Brev VMs but works on any Ubuntu/Debian or Fedora/RHEL host.

## What it sets up

1. **[Claude Code](https://docs.anthropic.com/claude/docs/claude-code)** — installed via the official native installer, then configured for unattended use:
   - `bypassPermissions` default mode, `skipDangerousModePermissionPrompt`, sandboxed
   - Model pinned to `claude-opus-4-7` at max effort
   - Onboarding wizard skipped (no theme / color-scheme prompt on first launch)
   - `ANTHROPIC_API_KEY` pre-approved if provided (no first-run approval prompt)
   - `claude` aliased to `claude --dangerously-skip-permissions` in interactive shells
2. **`gh` CLI** — latest release from the official `cli.github.com` apt/dnf repo (the distro-shipped `gh` predates `gh auth token` / `gh auth git-credential`).
3. **git** — `user.name` / `user.email` set from env, and `gh` registered as the `github.com` credential helper so `git clone` / `git push` reuse the gh-stored token with no interactive prompt.

## Quick start

From a Brev VM or any Linux host — fill in (or drop) any of the four env vars, then paste:

```bash
export ANTHROPIC_API_KEY=<your-anthropic-api-key>
export GH_TOKEN=<your-github-token>
export GIT_AUTHOR_NAME=<your-name>
export GIT_AUTHOR_EMAIL=<your@email>
curl -fsSL https://raw.githubusercontent.com/brycelelbach/unattended-brev-agent-bootstrap/main/bootstrap.bash | bash
source ~/.bashrc
```

Then run `claude`. If you didn't pass `GH_TOKEN`, sign in to gh (`gh auth login`) before using GitHub.

## Environment variables

All optional. Anything unset is simply skipped.

| Variable | Effect |
| --- | --- |
| `ANTHROPIC_API_KEY` | Last 20 characters written to `~/.claude.json` under `customApiKeyResponses.approved` so Claude Code doesn't prompt for approval. Also exported from the `~/.bashrc` managed block for future interactive shells. |
| `GH_TOKEN` | Exported from the `~/.bashrc` managed block. `gh` reads it from the environment directly, and since `gh auth git-credential` is registered as the `github.com` credential helper, `git clone` / `git push` reuse it automatically. |
| `GIT_AUTHOR_NAME` | `git config --global user.name` |
| `GIT_AUTHOR_EMAIL` | `git config --global user.email` |

## What the script touches

| Path | How |
| --- | --- |
| `~/.local/bin/claude` (+ `~/.local/bin/env`) | Written by the Claude Code native installer. |
| `~/.claude/settings.json` | Overwritten with unattended-mode defaults. Existing file backed up to `settings.json.bak.<timestamp>`. |
| `~/.claude.json` | Merged — `hasCompletedOnboarding=true` and optional `customApiKeyResponses.approved` entry. Existing file backed up to `.claude.json.bak.<timestamp>`. |
| `~/.bashrc` | Managed block between `# >>> unattended-claude-code bootstrap >>>` and `# <<< unattended-claude-code bootstrap <<<`. Rewritten wholesale on every run. |
| `~/.gitconfig` | `user.name`, `user.email`, and `credential.https://github.com.helper`. |
| System-wide | `gh` package, its apt/dnf source + signing keyring (requires `sudo`; script skips with a warning if passwordless `sudo` isn't available). |

## Re-running

Safe to re-run. Each run matches the current environment:

- The `~/.bashrc` managed block is replaced, not appended — so re-running **without** `ANTHROPIC_API_KEY` / `GH_TOKEN` set drops a previously-written export. If you want an export to persist across re-runs, keep the env var set when you re-run.
- `settings.json` and `.claude.json` are backed up (timestamped `.bak`) before being rewritten.
- `gh` and `claude` are skipped if already installed.
- `git config --global` is only touched for variables that are set.

## Related

- [`unattended-claude-code`](https://github.com/brycelelbach/unattended-claude-code) — upstream of the Claude Code portion of this script.
- [`gateroom`](https://github.com/brycelelbach/gateroom) — multi-node orchestration system that provisions Brev VMs and installs this bootstrap into agent containers.
