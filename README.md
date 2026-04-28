# autonomous-agent-bootstrap

A single idempotent bash script that turns a fresh Linux host into a ready-to-use Claude Code agent environment. Built for Brev VMs but works on any Ubuntu/Debian or Fedora/RHEL host.

## What it sets up

1. **[Claude Code](https://docs.anthropic.com/claude/docs/claude-code)** — installed via the official native installer, then configured for unattended use:
   - `bypassPermissions` default mode, `skipDangerousModePermissionPrompt`, sandboxed
   - Model selected via `AAB_CLAUDE_CODE_MODEL` (defaults to `claude-opus-4-7`), max effort
   - Inference provider selectable at runtime — either Anthropic's first-party API or any Anthropic-compatible third-party gateway. Switch with `claude_code_switch_inference_provider anthropic|third-party`.
   - Onboarding wizard skipped (no theme / color-scheme prompt on first launch)
   - `ANTHROPIC_API_KEY` pre-approved if provided (no first-run approval prompt)
   - `claude` aliased to `claude --dangerously-skip-permissions` in interactive shells
2. **`gh` CLI** — latest release from the official `cli.github.com` apt/dnf repo (the distro-shipped `gh` predates `gh auth token` / `gh auth git-credential`).
3. **git** — `user.name` / `user.email` set from env, and `gh` registered as the `github.com` credential helper so `git clone` / `git push` reuse the gh-stored token with no interactive prompt.
4. **Claude Code plugins** — marketplaces listed in [`claude_code_plugins.txt`](./claude_code_plugins.txt) are registered in `~/.claude/settings.json`'s `extraKnownMarketplaces`, and the plugins they declare are flipped on in `enabledPlugins`. Claude Code fetches them on next launch, no prompt. Defaults ship [agitentic](https://github.com/brycelelbach/agitentic) and [autocuda](https://github.com/brycelelbach/autocuda); add more by editing the file and re-running the bootstrap.

## Requirements

**To run the bootstrap:**

- Ubuntu/Debian (or Fedora/RHEL) host
- `bash`, `curl`, `python3`, `git`
- `sudo` — passwordless is nicest; the script warns and skips the `gh` install otherwise
- The `gh` CLI is installed by the script itself

**To run the tests** (see [Running the tests](#running-the-tests)):

- `bash`, `python3`, `curl`, `git`
- `shellcheck` — for lint
- `bats` (≥1.2) — for the unit suite
- `gitleaks` (pinned to v8.18.4 in CI) — for the secret scan
- `sudo` — the end-to-end job invokes `bootstrap.bash` for real

## Quick start

From a Brev VM or any Linux host, set your env vars and paste one of the following install recipes. All three write the same `~/.bashrc` block — they differ only in which credentials are populated and which provider is selected as the default.

### 1. First-party + third-party (both credentials, pick a default)

Use this if you have both a regular Anthropic API key *and* a third-party Anthropic-compatible gateway, and want to be able to flip between them with `claude_code_switch_inference_provider`.

```bash
export AAB_CLAUDE_CODE_INFERENCE_PROVIDER="anthropic"
export AAB_CLAUDE_CODE_MODEL="claude-opus-4-7"
export AAB_CLAUDE_CODE_MODEL_THIRD_PARTY_PREFIX="aws/anthropic/bedrock-"
export ANTHROPIC_API_KEY="..."
export ANTHROPIC_BASE_URL="..."
export ANTHROPIC_AUTH_TOKEN="..."
export GH_TOKEN="..."
export GIT_AUTHOR_NAME="Your Name"
export GIT_AUTHOR_EMAIL="youremail@gmail.com"
curl -fsSL https://raw.githubusercontent.com/brycelelbach/autonomous-agent-bootstrap/main/bootstrap.bash | bash
source ~/.bashrc
claude -p "Say hello from Claude Code"
```

### 2. First-party only

```bash
export AAB_CLAUDE_CODE_INFERENCE_PROVIDER="anthropic"
export AAB_CLAUDE_CODE_MODEL="claude-opus-4-7"
export ANTHROPIC_API_KEY="..."
export GH_TOKEN="..."
export GIT_AUTHOR_NAME="Your Name"
export GIT_AUTHOR_EMAIL="youremail@gmail.com"
curl -fsSL https://raw.githubusercontent.com/brycelelbach/autonomous-agent-bootstrap/main/bootstrap.bash | bash
source ~/.bashrc
claude -p "Say hello from Claude Code"
```

### 3. Third-party only

```bash
export AAB_CLAUDE_CODE_INFERENCE_PROVIDER="third-party"
export AAB_CLAUDE_CODE_MODEL="claude-opus-4-7"
export AAB_CLAUDE_CODE_MODEL_THIRD_PARTY_PREFIX="aws/anthropic/bedrock-"
export ANTHROPIC_BASE_URL="..."
export ANTHROPIC_AUTH_TOKEN="..."
export GH_TOKEN="..."
export GIT_AUTHOR_NAME="Your Name"
export GIT_AUTHOR_EMAIL="youremail@gmail.com"
curl -fsSL https://raw.githubusercontent.com/brycelelbach/autonomous-agent-bootstrap/main/bootstrap.bash | bash
source ~/.bashrc
claude -p "Say hello from Claude Code"
```

If you didn't pass `GH_TOKEN`, sign in to gh (`gh auth login`) before using GitHub.

## Switching inference providers

The bootstrap writes a `claude_code_switch_inference_provider` shell function into `~/.bashrc`. Call it with `anthropic` or `third-party` to flip the active provider — it rewrites the `AAB_CLAUDE_CODE_INFERENCE_PROVIDER` value in your `~/.bashrc` and re-sources it:

```bash
claude_code_switch_inference_provider third-party
```

The `if/else` in the managed block unsets the other provider's variables, so you won't get cross-provider env pollution.

## Environment variables

All optional. Anything unset is simply skipped.

| Variable | Effect |
| --- | --- |
| `AAB_CLAUDE_CODE_INFERENCE_PROVIDER` | `anthropic` (default) or `third-party`. Selects which branch of the `if/else` in the managed `~/.bashrc` block is active at runtime. Can be flipped later via `claude_code_switch_inference_provider`. |
| `AAB_CLAUDE_CODE_MODEL` | Unprefixed model name (e.g. `claude-opus-4-7`). Baked into `~/.claude/settings.json`'s `"model"` field and exported as `ANTHROPIC_MODEL` in the anthropic branch. Defaults to `claude-opus-4-7`. |
| `AAB_CLAUDE_CODE_MODEL_THIRD_PARTY_PREFIX` | Prepended to `AAB_CLAUDE_CODE_MODEL` when exporting `ANTHROPIC_MODEL` in the third-party branch (e.g. `aws/anthropic/bedrock-` + `claude-opus-4-7` → `aws/anthropic/bedrock-claude-opus-4-7`). |
| `ANTHROPIC_API_KEY` | Last 20 characters written to `~/.claude.json` under `customApiKeyResponses.approved` so Claude Code doesn't prompt for approval. Also exported from the anthropic branch of the `~/.bashrc` managed block. |
| `ANTHROPIC_BASE_URL` | Exported from the third-party branch. |
| `ANTHROPIC_AUTH_TOKEN` | Exported from the third-party branch. The third-party branch also exports `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` so context-management beta headers aren't sent to gateways that reject them. |
| `GH_TOKEN` | Exported from the `~/.bashrc` managed block. `gh` reads it from the environment directly, and since `gh auth git-credential` is registered as the `github.com` credential helper, `git clone` / `git push` reuse it automatically. |
| `GIT_AUTHOR_NAME` | `git config --global user.name` |
| `GIT_AUTHOR_EMAIL` | `git config --global user.email` |
| `AAB_CLAUDE_CODE_PLUGINS_FILE` | Path to a local `claude_code_plugins.txt`. If set and the file exists, it's used instead of fetching the canonical list. |
| `AAB_CLAUDE_CODE_PLUGINS_URL` | URL of the plugin list to fetch when `AAB_CLAUDE_CODE_PLUGINS_FILE` is unset. Defaults to `claude_code_plugins.txt` on `main` of this repo. |

## Managing the plugin list

Plugins are listed, one per line, in [`claude_code_plugins.txt`](./claude_code_plugins.txt) as GitHub `owner/repo` pointers to Claude Code plugin marketplaces (repos that contain `.claude-plugin/marketplace.json`). For each entry, the bootstrap fetches the marketplace manifest, reads the marketplace name and plugin names it declares, and merges:

- `extraKnownMarketplaces["<marketplace-name>"] = { "source": { "source": "github", "repo": "<owner/repo>" } }`
- `enabledPlugins["<plugin>@<marketplace>"] = true`

…into `~/.claude/settings.json`. Claude Code fetches and caches the plugins on next launch, at user scope, with no interactive prompt.

To add a plugin: append its marketplace's `owner/repo` to `claude_code_plugins.txt` and re-run the bootstrap. To install from your own fork or a different list, set `AAB_CLAUDE_CODE_PLUGINS_FILE=/path/to/your.txt` or `AAB_CLAUDE_CODE_PLUGINS_URL=https://...`.

## What the script touches

| Path | How |
| --- | --- |
| `~/.local/bin/claude` (+ `~/.local/bin/env`) | Written by the Claude Code native installer. |
| `~/.claude/settings.json` | Overwritten with unattended-mode defaults, then merged with `extraKnownMarketplaces` / `enabledPlugins` entries for each plugin in `claude_code_plugins.txt`. Existing file backed up to `settings.json.bak.<timestamp>` before the rewrite. |
| `~/.claude.json` | Merged — `hasCompletedOnboarding=true` and optional `customApiKeyResponses.approved` entry. Existing file backed up to `.claude.json.bak.<timestamp>`. |
| `~/.bashrc` | Managed block between `# >>> autonomous-agent-bootstrap >>>` and `# <<< autonomous-agent-bootstrap <<<`. Rewritten wholesale on every run. |
| `~/.gitconfig` | `user.name`, `user.email`, and `credential.https://github.com.helper`. |
| System-wide | `gh` package, its apt/dnf source + signing keyring (requires `sudo`; script skips with a warning if passwordless `sudo` isn't available). |

## Re-running

Safe to re-run. Each run matches the current environment:

- The `~/.bashrc` managed block is replaced, not appended — so re-running **without** `ANTHROPIC_API_KEY` / `GH_TOKEN` set drops a previously-written export. If you want an export to persist across re-runs, keep the env var set when you re-run.
- `settings.json` and `.claude.json` are backed up (timestamped `.bak`) before being rewritten.
- `gh` and `claude` are skipped if already installed.
- `git config --global` is only touched for variables that are set.

## Running the tests

All tests are driven by a single entry point, [`./test.bash`](./test.bash). `.github/workflows/ci.yml` calls the same flags, so "passes locally" == "will pass CI."

```bash
./test.bash              # lint + unit (default; fast, no side effects)
./test.bash --lint       # bash -n + shellcheck
./test.bash --unit       # bats suite in tests/
./test.bash --e2e        # runs bootstrap.bash on THIS host + assertions — see warning below
./test.bash --secrets    # gitleaks scan of full history + working tree
./test.bash --all        # everything above, in order
```

**`--e2e` is destructive.** It invokes `bootstrap.bash` for real against the current `$HOME`: overwrites `~/.claude/settings.json`, rewrites the `~/.bashrc` managed block, modifies global git config, and installs `claude` / `brev` / `gh`. Only run it on a disposable VM or container (which is how CI exercises it).

Install the test prerequisites on Ubuntu/Debian with:

```bash
sudo apt-get install -y bats shellcheck python3
# gitleaks (v8.18.4, matching CI)
curl -sSL "https://github.com/gitleaks/gitleaks/releases/download/v8.18.4/gitleaks_8.18.4_linux_x64.tar.gz" \
  | sudo tar -xz -C /usr/local/bin gitleaks
```
