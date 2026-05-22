# autonomous-agent-bootstrap

A single idempotent bash script that turns a fresh Linux host into a ready-to-use Claude Code and Codex agent environment. Built for Brev VMs but works on any Ubuntu/Debian host.

## What it sets up

1. **[Claude Code](https://docs.anthropic.com/claude/docs/claude-code)** — installed via the official native installer, then configured for unattended use:
   - `bypassPermissions` default mode, `skipDangerousModePermissionPrompt`, sandboxed
   - Edit / Write / Read for `~/.claude/**` and `~/.claude.json` pre-approved in `permissions.allow` so the agent can update its own config, agents, skills, and memory files without a prompt even when bypass mode is toggled off mid-session
   - First-party model selected via `AAB_CLAUDE_CODE_FIRST_PARTY_MODEL` (defaults to `claude-opus-4-7`), third-party model selected via `AAB_CLAUDE_CODE_THIRD_PARTY_MODEL`, effort selected via `AAB_CLAUDE_CODE_EFFORT` (defaults to `max`)
   - Inference provider selectable at runtime — either Anthropic's first-party API or any Anthropic-compatible third-party gateway. Switch with `claude_code_switch_inference_provider anthropic|third-party`.
   - Onboarding wizard skipped (no theme / color-scheme prompt on first launch)
   - `AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY` pre-approved if provided (no first-run approval prompt)
   - `claude` aliased to `claude --dangerously-skip-permissions` in interactive shells
2. **[Codex CLI](https://developers.openai.com/codex/cli)** — installed via OpenAI's standalone installer, then configured for unattended use:
   - `approval_policy = "never"` and `sandbox_mode = "danger-full-access"` in `~/.codex/config.toml`
   - `notice.hide_full_access_warning = true`
   - `shell_environment_policy.inherit = "all"` and `ignore_default_excludes = true` so spawned commands can see credential env vars such as `GH_TOKEN` and `OPENAI_API_KEY`
   - Model selected via `AAB_CODEX_FIRST_PARTY_MODEL` (defaults to `gpt-5.5`), reasoning effort via `AAB_CODEX_EFFORT` (defaults to `xhigh`)
   - `AAB_CODEX_FIRST_PARTY_API_KEY` logged in via `codex login --with-api-key` when provided, then exported as both `AAB_CODEX_FIRST_PARTY_API_KEY` and `OPENAI_API_KEY`
   - `codex` aliased to `codex --dangerously-bypass-approvals-and-sandbox` in interactive shells
   - The bootstrap user's `$HOME` and the bootstrap launch directory are marked trusted so project-local Codex config can load without a trust prompt
3. **[Brev CLI](https://github.com/brevdev/brev-cli)** — installed via the official installer, then logged in with organization-scoped API-key auth when `AAB_BREV_API_KEY` and `AAB_BREV_ORG_ID` are provided:
   - Runs `brev login --api-key ... --org-id ...` so Brev commands can run without a browser login prompt
   - Writes `~/.brev/onboarding_step.json` so the first `brev` invocation skips the interactive tutorial
   - Exports `AAB_BREV_API_KEY` and `AAB_BREV_ORG_ID` from the managed `~/.bashrc` block and mirrors them into `/etc/environment`
4. **Inference smoke tests** — as the final bootstrap step, runs `claude -p "hello world"` and `codex exec "hello world"` so missing or invalid model credentials fail before first agent launch.
5. **`gh` CLI** — latest release from the official `cli.github.com` apt repo (the distro-shipped `gh` predates `gh auth token` / `gh auth git-credential`).
6. **git** — `user.name` / `user.email` set from env, and `gh` registered as the `github.com` credential helper so `git clone` / `git push` reuse the gh-stored token with no interactive prompt. If `AAB_GIT_SIGNING_PRIVATE_KEY_B64` is set, git is also configured to sign every commit and tag with that key (see [SSH keys](#ssh-keys)).
7. **SSH keys for GitHub** — two independent optional env vars, each for a distinct role:
   - `AAB_GH_AUTH_SSH_PRIVATE_KEY_B64` -> the **authentication** identity. Decoded to `~/.ssh/id_aab_auth` (mode 0600) and wired as the `IdentityFile` for `github.com` in a managed block in `~/.ssh/config`.
   - `AAB_GIT_SIGNING_PRIVATE_KEY_B64` -> the **signing** key. Decoded to `~/.ssh/id_aab_signing` (mode 0600) and wired into git's `user.signingkey` / `commit.gpgsign` / `tag.gpgsign` config. Does **not** touch `~/.ssh/config`.

   See [SSH keys](#ssh-keys) for how to generate, encode, and upload them.
8. **Agent plugins** — marketplaces listed in [`agent_plugins.txt`](./agent_plugins.txt) are installed into both Claude Code and Codex. Claude Code also gets `~/.claude/settings.json` `extraKnownMarketplaces` / `enabledPlugins` entries so the plugins are enabled without a prompt. Defaults ship [agitentic](https://github.com/brycelelbach/agitentic) and [autocuda](https://github.com/brycelelbach-private/autocuda) (private); add more by editing the file and re-running the bootstrap. Plugin repos can be public or private — the bootstrap fetches each marketplace manifest via `gh api` when `gh` is authenticated (picks up `AAB_GH_TOKEN` via the exported `GH_TOKEN` runtime variable, or `gh auth login` credentials) and falls back to unauthenticated `raw.githubusercontent.com` otherwise. Entries the caller lacks access to are logged and skipped; they do not fail the bootstrap.

## Requirements

**To run the bootstrap:**

- Ubuntu/Debian host with `bash` and `apt-get`
- A bare `ubuntu:22.04` container image is a valid starting point — everything else (`curl`, `python3`, `git`, `tar`, `gawk`, `sudo`, `ca-certificates`, and `gh`) is installed by the script itself on first run
- Passwordless `sudo` (or running as root) — required so the script can install those packages; it warns and skips otherwise

**To run the tests** (see [Running the tests](#running-the-tests)):

- `bash`
- `shellcheck` — for lint
- `bats` (≥1.2) and `python3` — for the unit suite
- `gitleaks` (pinned to v8.18.4 in CI) — for the secret scan
- `docker` — for the bare-container end-to-end check
- The on-host `--e2e` job doesn't need anything beyond `bash`; the bootstrap it invokes installs its own prerequisites

## Quick start

From a Brev VM or any Linux host, set your config and paste one of the following install recipes. You can either pass settings via **env vars** (recipes 1–3) or via a **config file** ([recipe 4](#4-config-file)) — both accept the same keys.

### 1. First-party + third-party (both credentials, pick a default)

Use this if you have both a regular Anthropic API key *and* a third-party Anthropic-compatible gateway, and want to be able to flip between them with `claude_code_switch_inference_provider`.

```bash
export AAB_CLAUDE_CODE_INFERENCE_PROVIDER="anthropic"
export AAB_CLAUDE_CODE_FIRST_PARTY_MODEL="claude-opus-4-7"
export AAB_CLAUDE_CODE_THIRD_PARTY_MODEL="aws/anthropic/bedrock-claude-opus-4-7"
export AAB_CLAUDE_CODE_THIRD_PARTY_HAIKU_MODEL="aws/anthropic/claude-haiku-4-5-v1"
export AAB_CLAUDE_CODE_THIRD_PARTY_SONNET_MODEL="aws/anthropic/bedrock-claude-sonnet-4-6"
export AAB_CLAUDE_CODE_THIRD_PARTY_OPUS_MODEL="aws/anthropic/bedrock-claude-opus-4-7"
export AAB_CLAUDE_CODE_EFFORT="max"
export AAB_CODEX_FIRST_PARTY_MODEL="gpt-5.5"
export AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY="..."
export AAB_CODEX_FIRST_PARTY_API_KEY="..."
export AAB_CLAUDE_CODE_THIRD_PARTY_BASE_URL="..."
export AAB_CLAUDE_CODE_THIRD_PARTY_AUTH_TOKEN="..."
export AAB_BREV_API_KEY="..."
export AAB_BREV_ORG_ID="..."
export AAB_GH_TOKEN="..."
export AAB_GIT_AUTHOR_NAME="Your Name"
export AAB_GIT_AUTHOR_EMAIL="youremail@gmail.com"
curl -fsSL https://raw.githubusercontent.com/brycelelbach/autonomous-agent-bootstrap/main/bootstrap.bash | bash
source ~/.bashrc
claude -p "Say hello from Claude Code"
codex exec "Say hello from Codex"
```

### 2. First-party only

```bash
export AAB_CLAUDE_CODE_INFERENCE_PROVIDER="anthropic"
export AAB_CLAUDE_CODE_FIRST_PARTY_MODEL="claude-opus-4-7"
export AAB_CLAUDE_CODE_EFFORT="max"
export AAB_CODEX_FIRST_PARTY_MODEL="gpt-5.5"
export AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY="..."
export AAB_CODEX_FIRST_PARTY_API_KEY="..."
export AAB_BREV_API_KEY="..."
export AAB_BREV_ORG_ID="..."
export AAB_GH_TOKEN="..."
export AAB_GIT_AUTHOR_NAME="Your Name"
export AAB_GIT_AUTHOR_EMAIL="youremail@gmail.com"
curl -fsSL https://raw.githubusercontent.com/brycelelbach/autonomous-agent-bootstrap/main/bootstrap.bash | bash
source ~/.bashrc
claude -p "Say hello from Claude Code"
codex exec "Say hello from Codex"
```

### 3. Third-party only

```bash
export AAB_CLAUDE_CODE_INFERENCE_PROVIDER="third-party"
export AAB_CLAUDE_CODE_THIRD_PARTY_MODEL="aws/anthropic/bedrock-claude-opus-4-7"
export AAB_CLAUDE_CODE_THIRD_PARTY_HAIKU_MODEL="aws/anthropic/claude-haiku-4-5-v1"
export AAB_CLAUDE_CODE_THIRD_PARTY_SONNET_MODEL="aws/anthropic/bedrock-claude-sonnet-4-6"
export AAB_CLAUDE_CODE_THIRD_PARTY_OPUS_MODEL="aws/anthropic/bedrock-claude-opus-4-7"
export AAB_CLAUDE_CODE_EFFORT="max"
export AAB_CODEX_FIRST_PARTY_MODEL="gpt-5.5"
export AAB_CODEX_FIRST_PARTY_API_KEY="..."
export AAB_CLAUDE_CODE_THIRD_PARTY_BASE_URL="..."
export AAB_CLAUDE_CODE_THIRD_PARTY_AUTH_TOKEN="..."
export AAB_BREV_API_KEY="..."
export AAB_BREV_ORG_ID="..."
export AAB_GH_TOKEN="..."
export AAB_GIT_AUTHOR_NAME="Your Name"
export AAB_GIT_AUTHOR_EMAIL="youremail@gmail.com"
curl -fsSL https://raw.githubusercontent.com/brycelelbach/autonomous-agent-bootstrap/main/bootstrap.bash | bash
source ~/.bashrc
claude -p "Say hello from Claude Code"
codex exec "Say hello from Codex"
```

If you didn't pass `AAB_GH_TOKEN`, sign in to gh (`gh auth login`) before using GitHub.

To wire in GitHub SSH keys, export `AAB_GH_AUTH_SSH_PRIVATE_KEY_B64` (auth identity for `git`-over-SSH) and/or `AAB_GIT_SIGNING_PRIVATE_KEY_B64` (commit & tag signing) before running the bootstrap. See [SSH keys](#ssh-keys) for details.

### 4. Config file or stdin

Instead of long `export` chains, drop the same `KEY=VALUE` pairs in a file and pass its path as a positional arg, or pipe them on stdin:

```bash
cat > /tmp/aab.conf <<'CONF'
AAB_CLAUDE_CODE_INFERENCE_PROVIDER=anthropic
AAB_CLAUDE_CODE_FIRST_PARTY_MODEL=claude-opus-4-7
AAB_CLAUDE_CODE_EFFORT=max
AAB_CODEX_FIRST_PARTY_MODEL=gpt-5.5
AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY=...
AAB_CODEX_FIRST_PARTY_API_KEY=...
AAB_BREV_API_KEY=...
AAB_BREV_ORG_ID=...
AAB_GH_TOKEN=...
AAB_GIT_AUTHOR_NAME=Your Name
AAB_GIT_AUTHOR_EMAIL=you@example.com
CONF

# From a local checkout, by path:
bash bootstrap.bash /tmp/aab.conf

# From a local checkout, by stdin (heredoc, redirect, or any non-TTY pipe):
bash bootstrap.bash <<'CONF'
AAB_CLAUDE_CODE_FIRST_PARTY_MODEL=claude-opus-4-7
AAB_CLAUDE_CODE_EFFORT=max
AAB_CODEX_FIRST_PARTY_MODEL=gpt-5.5
AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY=...
AAB_CODEX_FIRST_PARTY_API_KEY=...
AAB_BREV_API_KEY=...
AAB_BREV_ORG_ID=...
AAB_GH_TOKEN=...
CONF

# From curl-pipe-bash with a positional path. The `-s --` hands the
# positional arg through to the piped script:
curl -fsSL https://raw.githubusercontent.com/brycelelbach/autonomous-agent-bootstrap/main/bootstrap.bash | bash -s -- /tmp/aab.conf

# From curl-pipe-bash with stdin. Process substitution (`bash <(...)`)
# frees stdin for the heredoc — the curl-pipe-bash form (`curl ... |
# bash`) leaves stdin attached to the closed curl pipe, so heredocs
# don't reach the script:
bash <(curl -fsSL https://raw.githubusercontent.com/brycelelbach/autonomous-agent-bootstrap/main/bootstrap.bash) <<'CONF'
AAB_CLAUDE_CODE_FIRST_PARTY_MODEL=claude-opus-4-7
AAB_CLAUDE_CODE_EFFORT=max
AAB_CODEX_FIRST_PARTY_MODEL=gpt-5.5
AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY=...
AAB_CODEX_FIRST_PARTY_API_KEY=...
AAB_BREV_API_KEY=...
AAB_BREV_ORG_ID=...
AAB_GH_TOKEN=...
CONF
```

The file (or stdin) is sourced via `set -a; . file; set +a`, so it has full access to bash syntax:

- `KEY=value`, `KEY="value with spaces"`, `KEY='single quoted'`
- `KEY="${OTHER:-default}"` and other parameter-expansion forms
- `KEY="$(some-cmd)"` command substitutions
- `\`-quoted multi-line values
- optional leading `export ` (with `KEY=value` semantics either way)
- `#` line comments anywhere; blank lines are ignored

Values containing shell metacharacters (`&`, `|`, `;`, `$`, `*`, `(`, `)`) need to be quoted — bash treats `URL=https://x.com/?a=b&c=d` as backgrounded `URL=...&` plus `c=d`, not a single value. Wrap the right-hand side in `"..."` or `'...'` whenever it contains anything that isn't `[A-Za-z0-9_./:%@-]`.

The flip side: a malformed config file aborts the bootstrap rather than silently warning. A typo'd line or one that runs an unknown command short-circuits the run on the first error, which is the safer default for a credentials-loading step.

**Env beats file.** If a variable is already set in the shell when you invoke the bootstrap, that value wins over the file entry. This makes one-off overrides easy to test without editing the file:

```bash
AAB_CLAUDE_CODE_FIRST_PARTY_MODEL=claude-haiku-4-5 bash bootstrap.bash /tmp/aab.conf
```

A corollary: there's no way to *unset* a variable from the file — if `FOO` is already exported in your shell, the file cannot force it to "unset" (only the env→file direction is valid). `FOO= bash bootstrap.bash aab.conf` lets you explicitly set `FOO` to empty, which most of the bootstrap's optional keys treat as "unset".

A missing / unreadable config-file path causes the bootstrap to exit non-zero before touching anything. An empty stdin (no positional path, TTY-attached or no data piped) is treated the same as recipe 1–3: the bootstrap runs with whatever env vars are already set in the shell.

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
| `AAB_CLAUDE_CODE_FIRST_PARTY_MODEL` | First-party Anthropic model name (e.g. `claude-opus-4-7`). Baked into `~/.claude/settings.json`'s `"model"` field and exported as `ANTHROPIC_MODEL` in the anthropic branch. Defaults to `claude-opus-4-7`. |
| `AAB_CLAUDE_CODE_FIRST_PARTY_HAIKU_MODEL` | First-party Anthropic haiku-tier model name. Claude Code uses this tier for background tasks (web search, summarization). Exported as `ANTHROPIC_DEFAULT_HAIKU_MODEL` in the anthropic branch. Defaults to `claude-haiku-4-5`. |
| `AAB_CLAUDE_CODE_FIRST_PARTY_SONNET_MODEL` | First-party Anthropic sonnet-tier model name, used when `/model` selects the sonnet tier mid-session. Exported as `ANTHROPIC_DEFAULT_SONNET_MODEL` in the anthropic branch. Defaults to `claude-sonnet-4-6`. |
| `AAB_CLAUDE_CODE_FIRST_PARTY_OPUS_MODEL` | First-party Anthropic opus-tier model name, used when `/model` selects the opus tier mid-session. Exported as `ANTHROPIC_DEFAULT_OPUS_MODEL` in the anthropic branch. Defaults to `claude-opus-4-7`. |
| `AAB_CLAUDE_CODE_THIRD_PARTY_MODEL` | Fully-qualified third-party gateway model ID. Exported verbatim as `ANTHROPIC_MODEL` in the third-party branch. Defaults to `claude-opus-4-7` when unset. |
| `AAB_CLAUDE_CODE_THIRD_PARTY_HAIKU_MODEL` | Fully-qualified third-party gateway haiku-tier model ID. Exported verbatim as `ANTHROPIC_DEFAULT_HAIKU_MODEL` in the third-party branch. Defaults to `claude-haiku-4-5`. |
| `AAB_CLAUDE_CODE_THIRD_PARTY_SONNET_MODEL` | Fully-qualified third-party gateway sonnet-tier model ID. Exported verbatim as `ANTHROPIC_DEFAULT_SONNET_MODEL` in the third-party branch. Defaults to `claude-sonnet-4-6`. |
| `AAB_CLAUDE_CODE_THIRD_PARTY_OPUS_MODEL` | Fully-qualified third-party gateway opus-tier model ID. Exported verbatim as `ANTHROPIC_DEFAULT_OPUS_MODEL` in the third-party branch. Defaults to `claude-opus-4-7`. |
| `AAB_CLAUDE_CODE_EFFORT` | Claude Code effort level. Written to `~/.claude/settings.json`'s `"effortLevel"` field and exported as `CLAUDE_CODE_EFFORT_LEVEL`. Defaults to `max`. |
| `AAB_CODEX_FIRST_PARTY_MODEL` | Codex first-party model name. Baked into `~/.codex/config.toml`'s `model` field. Defaults to `gpt-5.5`. |
| `AAB_CODEX_EFFORT` | Codex reasoning effort (`minimal`, `low`, `medium`, `high`, or `xhigh`). Baked into `~/.codex/config.toml`'s `model_reasoning_effort` field. Defaults to `xhigh`; invalid values fall back to `xhigh`. |
| `AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY` | Anthropic first-party API key. Last 20 characters are written to `~/.claude.json` under `customApiKeyResponses.approved` so Claude Code doesn't prompt for approval. Also exported as `ANTHROPIC_API_KEY` from the anthropic branch of the `~/.bashrc` managed block. |
| `AAB_CODEX_FIRST_PARTY_API_KEY` | OpenAI API key used by Codex. Piped into `codex login --with-api-key` when set, exported from the `~/.bashrc` managed block as both `AAB_CODEX_FIRST_PARTY_API_KEY` and `OPENAI_API_KEY`, and mirrored into `/etc/environment` so Codex can use API-key auth without a first-run sign-in prompt. |
| `AAB_BREV_API_KEY` | Brev organization-scoped API key. Used with `AAB_BREV_ORG_ID` to run `brev login --api-key ... --org-id ...`, exported from the `~/.bashrc` managed block, and mirrored into `/etc/environment`. |
| `AAB_BREV_ORG_ID` | Brev organization ID paired with `AAB_BREV_API_KEY`. Both values must be set to configure Brev API-key auth. |
| `AAB_SKIP_INFERENCE_SMOKE_TESTS` | Set to `1`, `true`, or `yes` to skip the final Claude Code and Codex `hello world` inference smoke tests. Intended for e2e tests that use synthetic credentials. |
| `AAB_CLAUDE_CODE_THIRD_PARTY_BASE_URL` | Base URL for the Anthropic-compatible third-party gateway. Also exported as `ANTHROPIC_BASE_URL` from the third-party branch. |
| `AAB_CLAUDE_CODE_THIRD_PARTY_AUTH_TOKEN` | Bearer token for the third-party gateway. Also exported as `ANTHROPIC_AUTH_TOKEN` from the third-party branch. The third-party branch also exports `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` so context-management beta headers aren't sent to gateways that reject them. |
| `AAB_GH_TOKEN` | GitHub personal access token. Exported from the `~/.bashrc` managed block as both `AAB_GH_TOKEN` and `GH_TOKEN`. `gh` reads `GH_TOKEN` from the environment directly, and since `gh auth git-credential` is registered as the `github.com` credential helper, `git clone` / `git push` reuse it automatically. |
| `AAB_GIT_AUTHOR_NAME` | `git config --global user.name` |
| `AAB_GIT_AUTHOR_EMAIL` | `git config --global user.email` |
| `AAB_GH_AUTH_SSH_PRIVATE_KEY_B64` | Base64-encoded OpenSSH private key used as the `github.com` **authentication** identity. Decoded to `~/.ssh/id_aab_auth` (mode 0600); public half at `~/.ssh/id_aab_auth.pub`. A managed block in `~/.ssh/config` wires it as `IdentityFile` for `github.com` with `IdentitiesOnly yes`. Does **not** touch git signing config. See [SSH keys](#ssh-keys). |
| `AAB_GIT_SIGNING_PRIVATE_KEY_B64` | Base64-encoded OpenSSH private key used **only** as the git commit/tag **signing** key. Decoded to `~/.ssh/id_aab_signing` (mode 0600); public half at `~/.ssh/id_aab_signing.pub`. Sets `gpg.format=ssh`, `user.signingkey=~/.ssh/id_aab_signing.pub`, `commit.gpgsign=true`, `tag.gpgsign=true`. Does **not** touch `~/.ssh/config`. See [SSH keys](#ssh-keys). |
| `AAB_AGENT_PLUGINS_FILE` | Path to a local `agent_plugins.txt`. If set and the file exists, it's used instead of fetching the canonical list. |
| `AAB_AGENT_PLUGINS_URL` | URL of the plugin list to fetch when `AAB_AGENT_PLUGINS_FILE` is unset. Defaults to `agent_plugins.txt` on `main` of this repo. |

## Managing the plugin list

Plugins are listed, one per line, in [`agent_plugins.txt`](./agent_plugins.txt) as GitHub `owner/repo` pointers to agent plugin marketplaces. The marketplace repo must contain `.claude-plugin/marketplace.json`; both Claude Code and Codex can read that marketplace shape. Entries can be public or private repos; private repos are fetched via `gh api` and require `gh` to be authenticated (via `AAB_GH_TOKEN`, `GITHUB_TOKEN`, or a stored `gh auth login` credential with access to the repo). For each entry, the bootstrap fetches the marketplace manifest, reads the marketplace name and plugin names it declares, and merges:

- `extraKnownMarketplaces["<marketplace-name>"] = { "source": { "source": "github", "repo": "<owner/repo>" } }`
- `enabledPlugins["<plugin>@<marketplace>"] = true`

…into `~/.claude/settings.json`. It also runs `claude plugin marketplace add`, `claude plugin install --scope user`, `codex plugin marketplace add`, and `codex plugin add` so both CLIs have the same plugin set registered and enabled.

To add a plugin: append its marketplace's `owner/repo` to `agent_plugins.txt` and re-run the bootstrap. To install from your own fork or a different list, set `AAB_AGENT_PLUGINS_FILE=/path/to/your.txt` or `AAB_AGENT_PLUGINS_URL=https://...`.

If the bootstrap can't fetch a marketplace manifest — usually because the repo is private and the active GitHub credential doesn't grant access — it logs the skip and moves on. Plugin install is treated as optional; an inaccessible entry does not fail the bootstrap.

## SSH keys

The bootstrap handles two independent optional env vars for GitHub SSH keys, each governing a distinct role. They can be set together, individually, or not at all.

| Env var | Role | Writes private key to | Touches `~/.ssh/config`? | Touches git signing config? |
| --- | --- | --- | --- | --- |
| `AAB_GH_AUTH_SSH_PRIVATE_KEY_B64` | GitHub authentication (clone/push/pull over SSH) | `~/.ssh/id_aab_auth` | **Yes** — managed block wires `github.com` -> `IdentityFile` | No |
| `AAB_GIT_SIGNING_PRIVATE_KEY_B64` | git commit / tag signing | `~/.ssh/id_aab_signing` | **No** | **Yes** — `gpg.format=ssh`, `user.signingkey`, `commit.gpgsign=true`, `tag.gpgsign=true` |

Keeping them separate lets you:

- Use an existing GitHub auth identity (provisioned by SSO, a password manager, or a hardware key) while the bootstrap manages only the signing key.
- Rotate one role without touching the other.
- Avoid granting read/write access to every repo your GitHub account can reach just because you wanted a signing key installed — the signing key is a low-privilege artifact whose only job is to produce a verifiable signature.

Both can hold the same key if you want, but the two env vars are the recommended way to keep the roles distinct.

### What each role writes

**`AAB_GH_AUTH_SSH_PRIVATE_KEY_B64`** — wires a managed block into `~/.ssh/config` for `github.com`:

```
# >>> autonomous-agent-bootstrap >>>
Host github.com
    IdentityFile ~/.ssh/id_aab_auth
    IdentitiesOnly yes
# <<< autonomous-agent-bootstrap <<<
```

Pre-existing entries in `~/.ssh/config` (other `Host` blocks, `IdentityFile` lines for other hosts) are preserved — re-runs rewrite **only** the managed block between the marker pair.

**`AAB_GIT_SIGNING_PRIVATE_KEY_B64`** — sets the following in `~/.gitconfig` via `git config --global`:

```
gpg.format        = ssh
user.signingkey   = ~/.ssh/id_aab_signing.pub
commit.gpgsign    = true
tag.gpgsign       = true
```

If you don't want every commit/tag signed, drop `commit.gpgsign` / `tag.gpgsign` after bootstrap (`git config --global --unset commit.gpgsign`, etc.), or flip them to `false`. The key on disk stays put; only the auto-signing preference changes.

### Generating and encoding a key

Generate a new ed25519 key (passphrase omitted so the bootstrap can read it non-interactively), then base64-encode the **private** key:

```bash
ssh-keygen -t ed25519 -C "you@example.com" -f ~/.ssh/new_key -N ""
base64 -w0 < ~/.ssh/new_key                        # Linux (GNU coreutils)
base64      < ~/.ssh/new_key | tr -d '\n'          # macOS / BSD
```

Copy the single-line output and set it on whichever env var matches the role:

```bash
export AAB_GH_AUTH_SSH_PRIVATE_KEY_B64="AAAA...=="      # auth identity
export AAB_GIT_SIGNING_PRIVATE_KEY_B64="AAAA...=="      # signing key
```

Upload the matching **public** key (`~/.ssh/new_key.pub`) to GitHub under *Settings → SSH and GPG keys → New SSH key*. GitHub lets you choose the key type:

- *Authentication Key* — for `git clone git@github.com:…`, `git push` over SSH, etc. Use this for the auth key.
- *Signing Key* — for GitHub to display ✅ next to signed commits and tags. Use this for the signing key.

You can upload the same public key under both types if you want a single blob to serve both roles. You can also upload different keys for each — this is the recommended setup if the auth identity is shared with other tooling (e.g. SSO-provisioned) and shouldn't double as a signing artifact.

## What the script touches

| Path | How |
| --- | --- |
| `~/.local/bin/claude` (+ `~/.local/bin/env`) | Written by the Claude Code native installer. |
| `~/.local/bin/codex` (+ `~/.codex/packages/standalone/...`) | Written by OpenAI's Codex standalone installer. |
| `~/.local/bin/brev` | Written by the Brev CLI installer. |
| `~/.claude/settings.json` | Overwritten with unattended-mode defaults, then merged with `extraKnownMarketplaces` / `enabledPlugins` entries for each plugin in `agent_plugins.txt`. Existing file backed up to `settings.json.bak.<timestamp>` before the rewrite. |
| `~/.claude/plugins/{marketplaces,cache}` | Written by `claude plugin marketplace add` and `claude plugin install --scope user` for each resolved plugin in `agent_plugins.txt`. |
| `~/.codex/config.toml` | Overwritten with unattended Codex defaults while preserving existing Codex plugin marketplace/plugin tables: `approval_policy = "never"`, `sandbox_mode = "danger-full-access"`, `web_search = "live"`, credential-preserving shell env inheritance, and trusted entries for `$HOME` plus the bootstrap launch directory. Existing file backed up to `config.toml.bak.<timestamp>` before the rewrite. |
| `~/.codex/auth.json` | Written by `codex login --with-api-key` when `AAB_CODEX_FIRST_PARTY_API_KEY` is set, selecting Codex API-key auth for first launch. |
| `~/.codex/.tmp/marketplaces/*`, `~/.codex/plugins/cache/*` | Written by `codex plugin marketplace add` and `codex plugin add` for each resolved plugin in `agent_plugins.txt`. |
| `~/.brev/credentials.json` | Written by `brev login --api-key ... --org-id ...` when `AAB_BREV_API_KEY` and `AAB_BREV_ORG_ID` are set, selecting Brev API-key auth for future commands. |
| `~/.brev/onboarding_step.json` | Written with the Brev tutorial steps marked complete. Existing file backed up to `onboarding_step.json.bak.<timestamp>` before the rewrite. |
| `~/.claude.json` | Merged — `hasCompletedOnboarding=true` and optional `customApiKeyResponses.approved` entry. Existing file backed up to `.claude.json.bak.<timestamp>`. |
| `~/.bashrc` | Managed block between `# >>> autonomous-agent-bootstrap >>>` and `# <<< autonomous-agent-bootstrap <<<`. Rewritten wholesale on every run. The Codex standalone installer may also add its own PATH block when `~/.local/bin` was not already on `PATH`. |
| `~/.gitconfig` | `user.name`, `user.email`, and `credential.https://github.com.helper`. When `AAB_GIT_SIGNING_PRIVATE_KEY_B64` is set, also `gpg.format=ssh`, `user.signingkey=~/.ssh/id_aab_signing.pub`, `commit.gpgsign=true`, `tag.gpgsign=true`. |
| `~/.ssh/id_aab_auth`, `~/.ssh/id_aab_auth.pub` | Written only when `AAB_GH_AUTH_SSH_PRIVATE_KEY_B64` is set. Private key mode 0600, public key mode 0644, `~/.ssh` dir mode 0700. |
| `~/.ssh/id_aab_signing`, `~/.ssh/id_aab_signing.pub` | Written only when `AAB_GIT_SIGNING_PRIVATE_KEY_B64` is set. Same mode layout as the auth pair. |
| `~/.ssh/config` | Managed block (same `# >>> … <<<` marker pair as `~/.bashrc`) mapping `github.com` to `~/.ssh/id_aab_auth`. Only touched when `AAB_GH_AUTH_SSH_PRIVATE_KEY_B64` is set — the signing-only flow leaves `~/.ssh/config` alone. Pre-existing entries outside the managed block are preserved. |
| `/etc/environment` | Managed block (same `# >>> … <<<` marker pair) mirroring the resolved provider / model / token state into a `KEY=VALUE` file PAM loads for every session. Pre-existing entries outside the block are preserved; re-runs replace the block in place. Requires `sudo`; the bootstrap warns and skips this step if passwordless `sudo` isn't available. |
| System-wide | `gh` package, its apt source + signing keyring (requires `sudo`; script skips with a warning if passwordless `sudo` isn't available). `openssh-client` is also installed on demand when either SSH-key env var is set and `ssh-keygen` isn't already available. |

## Re-running

Safe to re-run. Each run matches the current environment:

- The `~/.bashrc` managed block is replaced, not appended — so re-running **without** `AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY` / `AAB_CODEX_FIRST_PARTY_API_KEY` / `AAB_BREV_API_KEY` / `AAB_BREV_ORG_ID` / `AAB_GH_TOKEN` set drops a previously-written export. If you want an export to persist across re-runs, keep the env var set when you re-run.
- `settings.json`, `config.toml`, and `.claude.json` are backed up (timestamped `.bak`) before being rewritten.
- `gh`, `claude`, and `codex` are skipped or updated by their installers if already installed.
- Brev API-key login is re-run when both `AAB_BREV_API_KEY` and `AAB_BREV_ORG_ID` are set.
- Final Claude Code and Codex inference smoke tests run on each bootstrap unless `AAB_SKIP_INFERENCE_SMOKE_TESTS` is set.
- `git config --global` is only touched for variables that are set.
- The `~/.ssh/config` managed block is replaced in place on re-run; pre-existing entries outside the block are preserved. Re-running without `AAB_GH_AUTH_SSH_PRIVATE_KEY_B64` set leaves `~/.ssh/config` untouched — the block is **not** removed automatically. To turn signing off, use `git config --global --unset commit.gpgsign` (and similar) after dropping `AAB_GIT_SIGNING_PRIVATE_KEY_B64`.
- The `/etc/environment` managed block is replaced in place on re-run, mirroring the same resolved-at-bootstrap-time provider / model / token state that goes into `~/.bashrc`. The runtime `claude_code_switch_inference_provider` shell function only updates `~/.bashrc` (interactive sessions); to make a switch visible to non-interactive shells (ssh remote command, systemd `EnvironmentFile=`), re-run the bootstrap with the new provider.

## Running the tests

All tests are driven by a single entry point, [`./test.bash`](./test.bash). `.github/workflows/ci.yml` calls the same flags, so "passes locally" == "will pass CI."

```bash
./test.bash              # lint + unit (default; fast, no side effects)
./test.bash --lint       # bash -n + shellcheck
./test.bash --unit       # bats suite in tests/
./test.bash --e2e        # runs bootstrap.bash on THIS host + assertions — see warning below
./test.bash --docker     # same as --e2e, but inside a fresh ubuntu:22.04 container
./test.bash --secrets    # gitleaks scan of full history + working tree
./test.bash --all        # lint + unit + e2e + secrets, in order
```

**`--e2e` is destructive.** It invokes `bootstrap.bash` for real against the current `$HOME`: overwrites `~/.claude/settings.json`, overwrites `~/.codex/config.toml`, writes a synthetic `~/.codex/auth.json`, writes Brev API-key credentials when `AAB_BREV_API_KEY` and `AAB_BREV_ORG_ID` are set, rewrites the `~/.bashrc` managed block, modifies global git config, skips the live inference smoke tests, and installs `claude` / `codex` / `brev` / `gh`. Only run it on a disposable VM or container (which is how CI exercises it). **`--docker` is the safe alternative** — it does the same run inside a throwaway `ubuntu:22.04` container, and also serves as the stronger check that `bootstrap.bash` works against a bare image with nothing pre-installed.

Install the test prerequisites on Ubuntu/Debian with:

```bash
sudo apt-get install -y bats shellcheck python3
# gitleaks (v8.18.4, matching CI)
curl -sSL "https://github.com/gitleaks/gitleaks/releases/download/v8.18.4/gitleaks_8.18.4_linux_x64.tar.gz" \
  | sudo tar -xz -C /usr/local/bin gitleaks
```
