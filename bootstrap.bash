#!/usr/bin/env bash
# Bootstrap a fresh, non-interactive Claude Code install on a Linux host.
#
# Does the following, idempotently:
#   0. Installs any missing base dependencies (curl, python3, git, sudo,
#      ca-certificates) via apt-get, so the script runs on bare container
#      images that ship only apt-get. Skipped silently if already present.
#   1. Installs / upgrades Claude Code via the native installer.
#   2. Installs / upgrades the Brev CLI via the official install-latest.sh.
#   3. Installs / upgrades the gh CLI from the official apt repo
#      (system-wide; needs sudo).
#   ~. Registers Claude Code plugin marketplaces listed in
#      claude_code_plugins.txt (default: agitentic + autocuda) into
#      ~/.claude/settings.json's extraKnownMarketplaces, and enables the
#      plugins they declare in enabledPlugins. Claude Code picks these up
#      on next launch with no prompt (user scope).
#   4. Writes ~/.claude/settings.json with unattended-mode defaults
#      (bypassPermissions, sandboxed, max effort, opus-4-7).
#   5. Pre-populates ~/.claude.json with hasCompletedOnboarding=true so the
#      first `claude` launch skips the theme / color-scheme wizard, and —
#      if ANTHROPIC_API_KEY is set — pre-approves that key so the CLI
#      doesn't prompt for approval on first use either.
#   6. Writes ~/.brev/onboarding.json so the first `brev` invocation skips
#      the interactive tutorial.
#   7. Configures git: user.name, user.email (from env vars), and registers
#      gh as the github.com credential helper so `git clone` / `push` reuse
#      the gh CLI's stored token.
#  7b. If GH_AUTH_SSH_PRIVATE_KEY_B64 is set, decodes it to
#      ~/.ssh/id_aab_auth and writes a managed block to ~/.ssh/config
#      pointing github.com at that key.
#  7c. If GIT_SIGNING_PRIVATE_KEY_B64 is set, decodes it to
#      ~/.ssh/id_aab_signing and configures git to sign commits / tags
#      with it (gpg.format=ssh, user.signingkey, commit.gpgsign,
#      tag.gpgsign). Does NOT touch ~/.ssh/config — signing role only.
#   8. Appends PATH / alias / env exports to ~/.bashrc (managed block) so
#      interactive shells pick up ~/.local/bin, run `claude` with
#      --dangerously-skip-permissions, and — if ANTHROPIC_API_KEY was set
#      at bootstrap time — export it for future shells.
#   9. Mirrors the resolved credential / config env vars (provider tokens,
#      model names, GH_TOKEN, …) into a managed block in /etc/environment
#      so non-interactive shells (ssh remote command, systemd services
#      that EnvironmentFile=/etc/environment) see them too. Needs sudo;
#      warns and skips if passwordless sudo isn't available.
#
# Optional env vars:
#   AAB_CLAUDE_CODE_INFERENCE_PROVIDER
#                       Which inference backend Claude Code should use —
#                       'anthropic' (default, first-party Anthropic API) or
#                       'third-party' (any Anthropic-compatible gateway).
#                       Selects which branch of the if/else written to
#                       ~/.bashrc is active at runtime. Can be flipped later
#                       via the `claude_code_switch_inference_provider`
#                       function also written to ~/.bashrc.
#   AAB_CLAUDE_CODE_MODEL
#                       Unprefixed model name (e.g. 'claude-opus-4-7'). Baked
#                       into ~/.claude/settings.json's "model" field and
#                       exported as ANTHROPIC_MODEL in the anthropic branch.
#                       Defaults to claude-opus-4-7.
#   AAB_CLAUDE_CODE_MODEL_THIRD_PARTY_PREFIX
#                       Namespace prefix a third-party gateway uses in front
#                       of Anthropic model names. Prepended to every
#                       per-tier model name when building the third-party
#                       branch's ANTHROPIC_MODEL / ANTHROPIC_DEFAULT_*_MODEL
#                       exports (e.g. 'aws/anthropic/bedrock-' +
#                       'claude-opus-4-7' = 'aws/anthropic/bedrock-claude-
#                       opus-4-7').
#   AAB_CLAUDE_CODE_HAIKU_MODEL
#                       Unprefixed haiku-tier model name. Claude Code uses
#                       this tier for background tasks (web search,
#                       summarization, file naming). Exported as
#                       ANTHROPIC_DEFAULT_HAIKU_MODEL — raw in the anthropic
#                       branch, prefixed with
#                       AAB_CLAUDE_CODE_MODEL_THIRD_PARTY_PREFIX in the
#                       third-party branch. Defaults to claude-haiku-4-5.
#   AAB_CLAUDE_CODE_SONNET_MODEL
#                       Unprefixed sonnet-tier model name, used by Claude
#                       Code when /model selects the sonnet tier mid-session.
#                       Exported as ANTHROPIC_DEFAULT_SONNET_MODEL with the
#                       same prefix-or-not treatment. Defaults to
#                       claude-sonnet-4-6.
#   AAB_CLAUDE_CODE_OPUS_MODEL
#                       Unprefixed opus-tier model name, used when /model
#                       selects the opus tier mid-session. Exported as
#                       ANTHROPIC_DEFAULT_OPUS_MODEL with the same
#                       prefix-or-not treatment. Defaults to claude-opus-4-7.
#   ANTHROPIC_API_KEY   Anthropic first-party API key. Last 20 characters are
#                       pre-approved in ~/.claude.json's
#                       customApiKeyResponses.approved so Claude Code won't
#                       prompt, and the key is exported from the anthropic
#                       branch of the ~/.bashrc managed block.
#   ANTHROPIC_BASE_URL  Base URL of the Anthropic-compatible third-party
#                       gateway (points Claude Code at a non-Anthropic
#                       endpoint). Exported from the third-party branch of
#                       the ~/.bashrc managed block.
#   ANTHROPIC_AUTH_TOKEN
#                       Bearer token used to authenticate against the
#                       third-party gateway. Exported from the third-party
#                       branch of the ~/.bashrc managed block.
#   GH_TOKEN            GitHub personal access token. Exported from the
#                       ~/.bashrc managed block; gh reads it from the
#                       environment directly, and the github.com credential
#                       helper we register below delegates to
#                       `gh auth git-credential`, so git clone/push reuse it.
#   GIT_AUTHOR_NAME     Display name attached to git commits. Written to
#                       `git config --global user.name`.
#   GIT_AUTHOR_EMAIL    Email address attached to git commits. Written to
#                       `git config --global user.email`.
#   GH_AUTH_SSH_PRIVATE_KEY_B64
#                       Base64-encoded OpenSSH private key used as the
#                       github.com authentication identity. Decoded to
#                       ~/.ssh/id_aab_auth (mode 0600); its public half
#                       is written to ~/.ssh/id_aab_auth.pub (mode 0644);
#                       a managed block in ~/.ssh/config points github.com
#                       at it with IdentitiesOnly=yes. Does NOT configure
#                       git signing.
#   GIT_SIGNING_PRIVATE_KEY_B64
#                       Base64-encoded OpenSSH private key used ONLY as
#                       the git commit / tag signing key. Decoded to
#                       ~/.ssh/id_aab_signing (mode 0600); public half at
#                       ~/.ssh/id_aab_signing.pub (mode 0644). git is
#                       configured with gpg.format=ssh,
#                       user.signingkey=~/.ssh/id_aab_signing.pub,
#                       commit.gpgsign=true, tag.gpgsign=true. Does NOT
#                       touch ~/.ssh/config.
#   AAB_CLAUDE_CODE_PLUGINS_FILE
#                       Path to a local claude_code_plugins.txt listing
#                       plugin marketplaces to install. Read directly when
#                       set and the file exists; overrides
#                       AAB_CLAUDE_CODE_PLUGINS_URL.
#   AAB_CLAUDE_CODE_PLUGINS_URL
#                       URL to fetch claude_code_plugins.txt from when no
#                       local file is set. Defaults to the canonical file
#                       on main of this repo.
#
# Can be run from a local checkout or piped via `curl ... | bash`. Safe to
# re-run: existing settings.json and .claude.json are backed up before
# overwrite, and the ~/.bashrc managed block is replaced wholesale each
# run, so re-running without ANTHROPIC_API_KEY set will drop a previously-
# written export (this is intentional — re-runs match the current env).
#
# Optional config input — settings using the env-var contract above can
# come in via either of two channels (in order of preference):
#
#   1. Positional arg: a path to a config file
#      (`bash bootstrap.bash ./aab.conf` or `curl ... | bash -s -- ./aab.conf`).
#   2. Stdin pipe: heredoc, file redirect, or any non-TTY stdin
#      (`bash bootstrap.bash <<EOF ... EOF`,
#       `bash <(curl ...) <<EOF ... EOF`).
#
# The file (or piped content) is sourced via `set -a; . file; set +a`, so
# it has full access to bash syntax: `${VAR:-default}`, `$(cmd)`, multi-
# line strings, comments. Values containing shell metacharacters (`&`,
# `|`, `;`, `$`, …) need to be quoted; plain `KEY=value` lines do not.
#
# Caller-supplied env vars beat file values: `FOO=override bash
# bootstrap.bash aab.conf` is a one-line debug override without touching
# the file. An explicitly-empty `FOO= bash …` counts as set and still
# wins.

set -euo pipefail

CLAUDE_DIR="${HOME}/.claude"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"
CLAUDE_JSON="${HOME}/.claude.json"
BREV_DIR="${HOME}/.brev"
BREV_ONBOARDING="${BREV_DIR}/onboarding_step.json"
BASHRC="${HOME}/.bashrc"
BASHRC_MARKER_BEGIN="# >>> autonomous-agent-bootstrap >>>"
BASHRC_MARKER_END="# <<< autonomous-agent-bootstrap <<<"
SSH_DIR="${HOME}/.ssh"
SSH_CONFIG="${SSH_DIR}/config"
AUTH_KEY="${SSH_DIR}/id_aab_auth"
AUTH_KEY_PUB="${AUTH_KEY}.pub"
SIGNING_KEY="${SSH_DIR}/id_aab_signing"
SIGNING_KEY_PUB="${SIGNING_KEY}.pub"
SSH_MARKER_BEGIN="# >>> autonomous-agent-bootstrap >>>"
SSH_MARKER_END="# <<< autonomous-agent-bootstrap <<<"
ETC_ENV="/etc/environment"
ETC_ENV_MARKER_BEGIN="# >>> autonomous-agent-bootstrap >>>"
ETC_ENV_MARKER_END="# <<< autonomous-agent-bootstrap <<<"
DEFAULT_CLAUDE_CODE_MODEL="claude-opus-4-7"
DEFAULT_CLAUDE_CODE_HAIKU_MODEL="claude-haiku-4-5"
DEFAULT_CLAUDE_CODE_SONNET_MODEL="claude-sonnet-4-6"
DEFAULT_CLAUDE_CODE_OPUS_MODEL="claude-opus-4-7"

log() { printf '[bootstrap] %s\n' "$*"; }
warn() { printf '[bootstrap] WARN: %s\n' "$*" >&2; }

need_sudo() {
    if [ "$(id -u)" -eq 0 ]; then echo ""; else echo "sudo"; fi
}
SUDO=$(need_sudo)

# ---------------------------------------------------------------------------
# 0. Install base dependencies (curl / python3 / git / ca-certificates)
# via apt-get. Bare container images (e.g. ubuntu:22.04) ship with
# apt-get but nothing else, so we can't assume curl or python3 exist.
# Skip silently if everything's already present — the common case on a
# host with a developer-ish baseline.
# ---------------------------------------------------------------------------
install_base_deps() {
    local needed=()
    command -v curl    >/dev/null 2>&1 || needed+=(curl)
    command -v python3 >/dev/null 2>&1 || needed+=(python3)
    command -v git     >/dev/null 2>&1 || needed+=(git)
    # The Brev installer (install-latest.sh) invokes `sudo` unconditionally;
    # bare container images ship without sudo, so we install it even when
    # running as root. Sudo as uid 0 is a no-op passthrough.
    command -v sudo    >/dev/null 2>&1 || needed+=(sudo)
    # HTTPS curl / apt fetches from cli.github.com need the CA bundle.
    # Bare ubuntu images include it, but verify defensively.
    [ -f /etc/ssl/certs/ca-certificates.crt ] || needed+=(ca-certificates)

    if [ ${#needed[@]} -eq 0 ]; then
        return
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        warn "Missing base deps (${needed[*]}) and apt-get is not available; install them manually and re-run."
        return
    fi
    if [ -n "$SUDO" ] && ! sudo -n true 2>/dev/null; then
        warn "Missing base deps (${needed[*]}) and passwordless sudo is not available; install them manually and re-run."
        return
    fi

    log "Installing base deps: ${needed[*]}."
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -y
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${needed[@]}"
}

# ---------------------------------------------------------------------------
# 1. Install / upgrade Claude Code via the native installer.
# ---------------------------------------------------------------------------
install_claude() {
    log "Installing / updating Claude Code via native installer..."
    curl -fsSL https://claude.ai/install.sh | bash
}

# ---------------------------------------------------------------------------
# 2. Install / upgrade the Brev CLI via the official install-latest.sh.
# ---------------------------------------------------------------------------
install_brev() {
    log "Installing / updating Brev CLI via official installer..."
    curl -fsSL https://raw.githubusercontent.com/brevdev/brev-cli/main/bin/install-latest.sh | bash
}

# ---------------------------------------------------------------------------
# 3. Install gh CLI from the official cli.github.com repo.
#
# Ubuntu / Debian ship an old gh that predates `gh auth token` and
# `gh auth git-credential`. We specifically want those so the git
# credential helper wired up in configure_git() below actually works.
# ---------------------------------------------------------------------------
ensure_gh() {
    if [ -n "$SUDO" ] && ! sudo -n true 2>/dev/null; then
        warn "gh install needs sudo and passwordless sudo is not available; skipping."
        warn "Install gh manually from https://cli.github.com/ and re-run."
        return
    fi
    if command -v apt-get >/dev/null 2>&1; then
        log "Installing gh from cli.github.com apt repo."
        local keyring=/usr/share/keyrings/githubcli-archive-keyring.gpg
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            | $SUDO dd of="$keyring" status=none
        $SUDO chmod go+r "$keyring"
        echo "deb [arch=$(dpkg --print-architecture) signed-by=$keyring] https://cli.github.com/packages stable main" \
            | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null
        $SUDO apt-get update -y
        $SUDO apt-get install -y gh
    else
        warn "apt-get not found — skipping gh install. Install manually from https://cli.github.com/."
    fi
}

# ---------------------------------------------------------------------------
# 4. Write ~/.claude/settings.json.
# ---------------------------------------------------------------------------
write_settings() {
    mkdir -p "${CLAUDE_DIR}"
    if [[ -f "${SETTINGS_FILE}" ]]; then
        local backup
        backup="${SETTINGS_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
        cp "${SETTINGS_FILE}" "${backup}"
        log "Backed up existing settings.json -> ${backup}."
    fi
    local model="${AAB_CLAUDE_CODE_MODEL:-$DEFAULT_CLAUDE_CODE_MODEL}"
    # Belt-and-suspenders: bypassPermissions skips prompts for writes
    # under .claude/ already, but the explicit allow list also keeps
    # config / memory / agent / skill edits unprompted in 'default' or
    # 'acceptEdits' mode if a user toggles out of bypass mid-session.
    cat > "${SETTINGS_FILE}" <<JSON
{
  "model": "${model}",
  "effortLevel": "max",
  "permissions": {
    "defaultMode": "bypassPermissions",
    "allow": [
      "Edit(${HOME}/.claude/**)",
      "Write(${HOME}/.claude/**)",
      "Read(${HOME}/.claude/**)",
      "Edit(${HOME}/.claude.json)",
      "Write(${HOME}/.claude.json)",
      "Read(${HOME}/.claude.json)"
    ]
  },
  "skipDangerousModePermissionPrompt": true,
  "env": {
    "CLAUDE_CODE_SANDBOXED": "1",
    "CLAUDE_CODE_EFFORT_LEVEL": "max"
  }
}
JSON
    log "Wrote ${SETTINGS_FILE} (model=${model})."
}

# ---------------------------------------------------------------------------
# 5. Skip the first-run onboarding (theme prompt) AND pre-approve the
# ANTHROPIC_API_KEY fingerprint if one is set.
#
# Both gates live in ~/.claude.json (NOT ~/.claude/settings.json):
#   - hasCompletedOnboarding controls the theme / color-scheme wizard
#   - customApiKeyResponses.approved is a list of API-key fingerprints
#     (last 20 chars of the key); if the runtime ANTHROPIC_API_KEY matches
#     one, Claude starts without prompting for approval.
# We merge into an existing .claude.json rather than overwriting so we
# preserve auth tokens, userID, and any prior approvals.
# ---------------------------------------------------------------------------
skip_onboarding() {
    command -v python3 >/dev/null 2>&1 || { log "ERROR: python3 required to edit ~/.claude.json."; exit 1; }
    python3 - "${CLAUDE_JSON}" "${ANTHROPIC_API_KEY:-}" <<'PY'
import json, os, shutil, sys, time
path = sys.argv[1]
api_key = sys.argv[2] if len(sys.argv) > 2 else ""
data = {}
if os.path.exists(path):
    backup = f"{path}.bak.{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(path, backup)
    print(f"[bootstrap] Backed up existing .claude.json -> {backup}.")
    try:
        with open(path) as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError):
        data = {}
data["hasCompletedOnboarding"] = True
if api_key:
    fp = api_key[-20:]
    resp = data.setdefault("customApiKeyResponses", {})
    approved = resp.setdefault("approved", [])
    if fp not in approved:
        approved.append(fp)
    resp.setdefault("rejected", [])
    print(f"[bootstrap] Pre-approved ANTHROPIC_API_KEY fingerprint ...{fp}.")
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2)
print(f"[bootstrap] Set hasCompletedOnboarding=true in {path}.")
PY
}

# ---------------------------------------------------------------------------
# 6. Write ~/.brev/onboarding.json to disable the Brev interactive tutorial.
# ---------------------------------------------------------------------------
skip_brev_onboarding() {
    mkdir -p "${BREV_DIR}"
    if [[ -f "${BREV_ONBOARDING}" ]]; then
        local backup
        backup="${BREV_ONBOARDING}.bak.$(date +%Y%m%d-%H%M%S)"
        cp "${BREV_ONBOARDING}" "${backup}"
        log "Backed up existing onboarding.json -> ${backup}."
    fi
    cat > "${BREV_ONBOARDING}" <<'JSON'
{"step": 1, "hasRunBrevShell": true, "hasRunBrevOpen": true}
JSON
    log "Wrote ${BREV_ONBOARDING}."
}

# ---------------------------------------------------------------------------
# 7. Configure git: identity + gh as github.com credential helper.
# ---------------------------------------------------------------------------
configure_git() {
    if ! command -v git >/dev/null 2>&1; then
        warn "git not installed — skipping git configuration."
        return
    fi
    if [ -n "${GIT_AUTHOR_NAME:-}" ]; then
        git config --global user.name "$GIT_AUTHOR_NAME"
        log "git user.name = $GIT_AUTHOR_NAME"
    fi
    if [ -n "${GIT_AUTHOR_EMAIL:-}" ]; then
        git config --global user.email "$GIT_AUTHOR_EMAIL"
        log "git user.email = $GIT_AUTHOR_EMAIL"
    fi
    if command -v gh >/dev/null 2>&1; then
        git config --global 'credential.https://github.com.helper' '!gh auth git-credential'
        log "Registered gh as github.com credential helper."
    fi
}

# ---------------------------------------------------------------------------
# 7b. Install SSH keys supplied via $GH_AUTH_SSH_PRIVATE_KEY_B64 (for
# github.com auth: clone/push over SSH) and/or $GIT_SIGNING_PRIVATE_KEY_B64
# (for git commit/tag signing). These are two separate roles and the
# bootstrap treats them independently: either may be set, or both, or
# neither. The signing key path does NOT touch ~/.ssh/config.
# ---------------------------------------------------------------------------

# _ensure_ssh_keygen: Idempotently install openssh-client if ssh-keygen is
# missing. Returns 0 iff ssh-keygen is callable afterward.
_ensure_ssh_keygen() {
    command -v ssh-keygen >/dev/null 2>&1 && return 0
    if ! command -v apt-get >/dev/null 2>&1; then
        warn "ssh-keygen not installed and apt-get unavailable."
        return 1
    fi
    if [ -n "$SUDO" ] && ! sudo -n true 2>/dev/null; then
        warn "ssh-keygen not installed and passwordless sudo unavailable."
        return 1
    fi
    log "Installing openssh-client for ssh-keygen."
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-client
    command -v ssh-keygen >/dev/null 2>&1
}

# _decode_ssh_key <encoded> <dest> <label>
# Decodes a base64-encoded OpenSSH private key to <dest> (mode 0600) and
# derives the public half to <dest>.pub (mode 0644). <label> is the env
# var name for log / warn messages. Returns 0 on success. On failure,
# cleans up any partial files and warns with <label> for context.
_decode_ssh_key() {
    local encoded="$1" dest="$2" label="$3"
    local dest_pub="${dest}.pub"

    mkdir -p "$SSH_DIR"
    chmod 0700 "$SSH_DIR"

    if ! printf '%s' "$encoded" | base64 -d > "$dest" 2>/dev/null; then
        warn "${label} is not valid base64; skipping."
        rm -f "$dest"
        return 1
    fi
    chmod 0600 "$dest"

    if ! ssh-keygen -y -f "$dest" > "$dest_pub" 2>/dev/null; then
        warn "${label} did not decode to a valid SSH private key; skipping."
        rm -f "$dest" "$dest_pub"
        return 1
    fi
    chmod 0644 "$dest_pub"
    return 0
}

# _rewrite_ssh_config_block: Idempotently rewrite the managed block in
# ~/.ssh/config so github.com uses the supplied IdentityFile. Strips any
# previous managed block plus its trailing padding so the file size stays
# stable across re-runs and pre-existing entries outside the block are
# preserved.
_rewrite_ssh_config_block() {
    local key="$1"
    touch "$SSH_CONFIG"
    python3 - "$SSH_CONFIG" "$key" "$SSH_MARKER_BEGIN" "$SSH_MARKER_END" <<'PY'
import sys
path, key, begin, end = sys.argv[1:5]
with open(path) as f:
    lines = f.read().splitlines()
out = []
in_block = False
for line in lines:
    if line == begin:
        in_block = True
        continue
    if line == end:
        in_block = False
        continue
    if not in_block:
        out.append(line)
while out and out[-1].strip() == "":
    out.pop()
block = [
    begin,
    "Host github.com",
    f"    IdentityFile {key}",
    "    IdentitiesOnly yes",
    end,
]
parts = []
if out:
    parts.append("\n".join(out))
    parts.append("")  # one blank line between user content and our block
parts.append("\n".join(block))
with open(path, "w") as f:
    f.write("\n".join(parts) + "\n")
PY
    chmod 0600 "$SSH_CONFIG"
}

# install_auth_ssh_key: Decode $GH_AUTH_SSH_PRIVATE_KEY_B64 to
# ~/.ssh/id_aab_auth and wire it as the IdentityFile for github.com in
# ~/.ssh/config. Does NOT touch git signing config. Silent no-op when the
# env var is unset.
install_auth_ssh_key() {
    local encoded="${GH_AUTH_SSH_PRIVATE_KEY_B64:-}"
    [ -z "$encoded" ] && return

    if ! command -v base64 >/dev/null 2>&1; then
        warn "base64 not installed; cannot decode GH_AUTH_SSH_PRIVATE_KEY_B64; skipping."
        return
    fi
    _ensure_ssh_keygen || { warn "Skipping GH_AUTH_SSH_PRIVATE_KEY_B64 install (ssh-keygen unavailable)."; return; }
    _decode_ssh_key "$encoded" "$AUTH_KEY" "GH_AUTH_SSH_PRIVATE_KEY_B64" || return 0

    _rewrite_ssh_config_block "$AUTH_KEY"
    log "Installed GitHub auth SSH key at $AUTH_KEY (pub $AUTH_KEY_PUB); wired github.com identity in $SSH_CONFIG."
}

# install_signing_ssh_key: Decode $GIT_SIGNING_PRIVATE_KEY_B64 to
# ~/.ssh/id_aab_signing and configure git to sign commits/tags with it.
# Does NOT touch ~/.ssh/config — this key is for signing only. Silent
# no-op when the env var is unset.
install_signing_ssh_key() {
    local encoded="${GIT_SIGNING_PRIVATE_KEY_B64:-}"
    [ -z "$encoded" ] && return

    if ! command -v base64 >/dev/null 2>&1; then
        warn "base64 not installed; cannot decode GIT_SIGNING_PRIVATE_KEY_B64; skipping."
        return
    fi
    _ensure_ssh_keygen || { warn "Skipping GIT_SIGNING_PRIVATE_KEY_B64 install (ssh-keygen unavailable)."; return; }
    _decode_ssh_key "$encoded" "$SIGNING_KEY" "GIT_SIGNING_PRIVATE_KEY_B64" || return 0

    if command -v git >/dev/null 2>&1; then
        git config --global gpg.format ssh
        git config --global user.signingkey "$SIGNING_KEY_PUB"
        git config --global commit.gpgsign true
        git config --global tag.gpgsign true
        log "Configured git to sign commits and tags with $SIGNING_KEY_PUB."
    else
        warn "git not installed; skipping SSH signing config."
    fi
}

# ---------------------------------------------------------------------------
# 8. Install Claude Code plugins listed in claude_code_plugins.txt.
#
# Each line is a GitHub owner/repo that hosts a Claude Code marketplace
# (repo contains .claude-plugin/marketplace.json). We fetch each
# marketplace.json to discover the marketplace name and the plugin
# names, then merge them into ~/.claude/settings.json under
# extraKnownMarketplaces (so the marketplace is known) and
# enabledPlugins (so the plugin is turned on). Claude Code picks these
# up on next launch, user-scope, no prompt.
#
# The list is taken from (in order): $AAB_CLAUDE_CODE_PLUGINS_FILE if
# set to an existing path, otherwise fetched from
# $AAB_CLAUDE_CODE_PLUGINS_URL (defaults to main@autonomous-agent-bootstrap).
# ---------------------------------------------------------------------------
PLUGINS_DEFAULT_URL="https://raw.githubusercontent.com/brycelelbach/autonomous-agent-bootstrap/main/claude_code_plugins.txt"
install_claude_code_plugins() {
    command -v python3 >/dev/null 2>&1 || { warn "python3 required for plugin install; skipping."; return; }
    local plugins_file="${AAB_CLAUDE_CODE_PLUGINS_FILE:-}"
    local plugins_url="${AAB_CLAUDE_CODE_PLUGINS_URL:-$PLUGINS_DEFAULT_URL}"
    local content=""
    if [ -n "$plugins_file" ] && [ -f "$plugins_file" ]; then
        content=$(cat "$plugins_file")
        log "Reading plugin list from ${plugins_file}."
    elif content=$(curl -fsSL "$plugins_url" 2>/dev/null); then
        log "Fetched plugin list from ${plugins_url}."
    else
        warn "Could not read plugin list (file=${plugins_file:-unset}, url=${plugins_url}); skipping plugin install."
        return
    fi

    # Strip comments and blanks → one repo per line.
    local -a repos=()
    while IFS= read -r line; do
        line="${line%%#*}"
        # trim
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue
        repos+=("$line")
    done <<< "$content"

    if [ ${#repos[@]} -eq 0 ]; then
        log "Plugin list is empty; skipping plugin install."
        return
    fi

    # Private plugin repos need an authenticated fetch. Prefer `gh api` when
    # it's installed and authenticated (works for both public and private
    # repos); fall back to unauthenticated raw.githubusercontent.com so
    # public plugins still work on hosts without a gh login.
    local use_gh=0
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        use_gh=1
    fi

    # Collect resolved tuples (repo|marketplace|plugin) for every plugin.
    local -a tuples=()
    local repo marketplace_json marketplace_name plugin_names plugin_name
    for repo in "${repos[@]}"; do
        marketplace_json=""
        for branch in main master; do
            if [ $use_gh -eq 1 ]; then
                marketplace_json=$(gh api -H "Accept: application/vnd.github.v3.raw" \
                    "repos/${repo}/contents/.claude-plugin/marketplace.json?ref=${branch}" 2>/dev/null) \
                    || marketplace_json=""
            fi
            if [ -z "$marketplace_json" ]; then
                marketplace_json=$(curl -fsSL "https://raw.githubusercontent.com/${repo}/${branch}/.claude-plugin/marketplace.json" 2>/dev/null) \
                    || marketplace_json=""
            fi
            [ -n "$marketplace_json" ] && break
        done
        if [ -z "$marketplace_json" ]; then
            # Most commonly this means the repo is private and the caller
            # lacks access (or gh isn't authenticated). Plugin install is an
            # optional step — log and move on without failing the bootstrap.
            log "Could not fetch .claude-plugin/marketplace.json from ${repo} (private repo without access?); skipping."
            continue
        fi
        marketplace_name=$(printf '%s' "$marketplace_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))') || marketplace_name=""
        if [ -z "$marketplace_name" ]; then
            warn "${repo}/.claude-plugin/marketplace.json has no 'name'; skipping."
            continue
        fi
        plugin_names=$(printf '%s' "$marketplace_json" | python3 -c 'import json,sys; [print(p["name"]) for p in json.load(sys.stdin).get("plugins",[]) if p.get("name")]')
        if [ -z "$plugin_names" ]; then
            warn "${repo} marketplace lists no plugins; skipping."
            continue
        fi
        while IFS= read -r plugin_name; do
            [ -z "$plugin_name" ] && continue
            tuples+=("${repo}|${marketplace_name}|${plugin_name}")
        done <<< "$plugin_names"
    done

    if [ ${#tuples[@]} -eq 0 ]; then
        warn "No plugins resolved; skipping settings.json update."
        return
    fi

    # Merge into ~/.claude/settings.json. write_settings has already run,
    # so the file exists and is valid JSON.
    python3 - "$SETTINGS_FILE" "${tuples[@]}" <<'PY'
import json, sys
path = sys.argv[1]
tuples = sys.argv[2:]
with open(path) as f:
    data = json.load(f)
extra = data.setdefault("extraKnownMarketplaces", {})
enabled = data.setdefault("enabledPlugins", {})
for t in tuples:
    repo, marketplace, plugin = t.split("|", 2)
    extra[marketplace] = {"source": {"source": "github", "repo": repo}}
    enabled[f"{plugin}@{marketplace}"] = True
    print(f"[bootstrap] Enabled plugin {plugin}@{marketplace} from github {repo}.")
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PY

    # settings.json's extraKnownMarketplaces and enabledPlugins are
    # advisory: Claude Code's `plugin` CLI maintains its own registry
    # at ~/.claude/plugins/{known_marketplaces,installed_plugins}.json
    # that only `claude plugin marketplace add` + `claude plugin
    # install` populate. Without those, every `claude` (and every
    # ACP-driven harness like @openclaw/acpx that spawns claude) starts
    # with an empty installed_plugins.json — the agent's session-start
    # skills list contains only the bundled defaults, none of the
    # user-configured plugins. Materialise the install here so the
    # bootstrap leaves the user with a fully-registered plugin set.
    local claude_bin=""
    if command -v claude >/dev/null 2>&1; then
        claude_bin=$(command -v claude)
    elif [ -x "${HOME}/.local/bin/claude" ]; then
        claude_bin="${HOME}/.local/bin/claude"
    else
        warn "claude binary not on PATH; skipping plugin install (settings.json was still written)."
        return
    fi

    # Snapshot the post-write_settings + post-merge settings.json so
    # the re-merge below can restore AAB-managed top-level keys that
    # Claude Code's plugin CLI strips on re-serialise.
    cp "$SETTINGS_FILE" "${SETTINGS_FILE}.pre-plugin-install.bak"

    # Dedupe repos before `marketplace add` (one marketplace can ship
    # several plugins; a 1-to-1 add per tuple would re-clone N times).
    local -A seen_repos=()
    local t repo marketplace plugin
    for t in "${tuples[@]}"; do
        repo="${t%%|*}"
        if [ -z "${seen_repos[$repo]:-}" ]; then
            log "Adding marketplace ${repo} to claude's plugin registry."
            "$claude_bin" plugin marketplace add "$repo" 2>&1 | sed 's/^/  /' || \
                warn "claude plugin marketplace add ${repo} returned non-zero (private repo without access? skipping)."
            seen_repos[$repo]=1
        fi
    done

    for t in "${tuples[@]}"; do
        repo="${t%%|*}"
        marketplace="${t#*|}"
        plugin="${marketplace#*|}"
        marketplace="${marketplace%|*}"
        log "Installing plugin ${plugin}@${marketplace}."
        "$claude_bin" plugin install "${plugin}@${marketplace}" --scope user 2>&1 | sed 's/^/  /' || \
            warn "claude plugin install ${plugin}@${marketplace} returned non-zero."
    done

    # `claude plugin marketplace add` / `claude plugin install --scope
    # user` re-serialise ~/.claude/settings.json against Claude Code's
    # internal schema, which drops any top-level keys the schema
    # doesn't enumerate (notably `effortLevel` — written by
    # write_settings, asserted by tests/e2e-assertions.bash). Re-merge
    # the AAB-managed top-level keys back in from a snapshot taken
    # before the claude calls ran so the on-disk shape stays a
    # superset of what write_settings produced.
    if [ -f "${SETTINGS_FILE}.pre-plugin-install.bak" ]; then
        python3 - "$SETTINGS_FILE" "${SETTINGS_FILE}.pre-plugin-install.bak" <<'PY'
import json, sys
live_path, snap_path = sys.argv[1], sys.argv[2]
with open(live_path) as f:
    live = json.load(f)
with open(snap_path) as f:
    snap = json.load(f)
# Re-merge keys that AAB owns but Claude Code's plugin CLI strips on
# re-serialise. Keep the live values for keys the CLI updated.
for k in ("model", "effortLevel", "permissions", "skipDangerousModePermissionPrompt", "env"):
    if k in snap and k not in live:
        live[k] = snap[k]
with open(live_path, "w") as f:
    json.dump(live, f, indent=2)
PY
        rm -f "${SETTINGS_FILE}.pre-plugin-install.bak"
    fi
}

# ---------------------------------------------------------------------------
# 9. Rewrite the unattended-mode block in ~/.bashrc.
#
# The block is identified by the BEGIN/END markers. On re-run we strip the
# old block and append a fresh one, so the output always matches the
# current env — re-running without ANTHROPIC_API_KEY set will drop a
# previously-written export, which is what the header comment promises.
# ---------------------------------------------------------------------------
update_bashrc() {
    touch "${BASHRC}"
    if grep -qF "${BASHRC_MARKER_BEGIN}" "${BASHRC}"; then
        local tmp
        tmp=$(mktemp)
        awk -v begin="${BASHRC_MARKER_BEGIN}" -v end="${BASHRC_MARKER_END}" '
            $0 == begin { skip=1; next }
            $0 == end   { skip=0; next }
            !skip { print }
        ' "${BASHRC}" > "$tmp"
        mv "$tmp" "${BASHRC}"
        log "Replaced existing autonomous-agent-bootstrap block in ${BASHRC}."
    fi

    local provider="${AAB_CLAUDE_CODE_INFERENCE_PROVIDER:-anthropic}"
    if [ "$provider" != "anthropic" ] && [ "$provider" != "third-party" ]; then
        warn "AAB_CLAUDE_CODE_INFERENCE_PROVIDER='${provider}' is not 'anthropic' or 'third-party'; defaulting to 'anthropic'."
        provider="anthropic"
    fi
    local model="${AAB_CLAUDE_CODE_MODEL:-$DEFAULT_CLAUDE_CODE_MODEL}"
    local haiku_model="${AAB_CLAUDE_CODE_HAIKU_MODEL:-$DEFAULT_CLAUDE_CODE_HAIKU_MODEL}"
    local sonnet_model="${AAB_CLAUDE_CODE_SONNET_MODEL:-$DEFAULT_CLAUDE_CODE_SONNET_MODEL}"
    local opus_model="${AAB_CLAUDE_CODE_OPUS_MODEL:-$DEFAULT_CLAUDE_CODE_OPUS_MODEL}"
    local third_party_prefix="${AAB_CLAUDE_CODE_MODEL_THIRD_PARTY_PREFIX:-}"
    local third_party_model="${third_party_prefix}${model}"
    local third_party_haiku_model="${third_party_prefix}${haiku_model}"
    local third_party_sonnet_model="${third_party_prefix}${sonnet_model}"
    local third_party_opus_model="${third_party_prefix}${opus_model}"

    {
        printf '\n%s\n' "${BASHRC_MARKER_BEGIN}"
        printf '%s\n' \
            '# Sources env file created by the Claude Code native installer, ensures' \
            "# ~/.local/bin is on PATH, and makes every interactive 'claude' invocation" \
            '# skip the permission prompt so the agent can run unattended.' \
            'if [ -f "$HOME/.local/bin/env" ]; then' \
            '    . "$HOME/.local/bin/env"' \
            'fi' \
            'export PATH="$HOME/.local/bin:$PATH"' \
            'export CLAUDE_CODE_SANDBOXED=1' \
            "alias claude='claude --dangerously-skip-permissions'"
        if [ -n "${GH_TOKEN:-}" ]; then
            printf 'export GH_TOKEN=%q\n' "$GH_TOKEN"
        fi

        # Inner managed block — rewritten in place by
        # claude_code_switch_inference_provider below.
        printf '\n# >>> autonomous-agent-bootstrap AAB_CLAUDE_CODE_INFERENCE_PROVIDER >>>\n'
        printf 'AAB_CLAUDE_CODE_INFERENCE_PROVIDER="%s"\n' "$provider"
        printf '# <<< autonomous-agent-bootstrap AAB_CLAUDE_CODE_INFERENCE_PROVIDER <<<\n\n'

        printf 'if [ "${AAB_CLAUDE_CODE_INFERENCE_PROVIDER}" = "anthropic" ]; then\n'
        printf '    unset ANTHROPIC_BASE_URL\n'
        printf '    unset ANTHROPIC_AUTH_TOKEN\n'
        printf '    unset CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS\n'
        if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
            printf '    export ANTHROPIC_API_KEY=%q\n' "$ANTHROPIC_API_KEY"
        fi
        printf '    export ANTHROPIC_MODEL=%q\n' "$model"
        printf '    export ANTHROPIC_DEFAULT_HAIKU_MODEL=%q\n' "$haiku_model"
        printf '    export ANTHROPIC_DEFAULT_SONNET_MODEL=%q\n' "$sonnet_model"
        printf '    export ANTHROPIC_DEFAULT_OPUS_MODEL=%q\n' "$opus_model"
        printf 'else\n'
        printf '    unset ANTHROPIC_API_KEY\n'
        if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
            printf '    export ANTHROPIC_BASE_URL=%q\n' "$ANTHROPIC_BASE_URL"
        fi
        if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
            printf '    export ANTHROPIC_AUTH_TOKEN=%q\n' "$ANTHROPIC_AUTH_TOKEN"
        fi
        printf '    export ANTHROPIC_MODEL=%q\n' "$third_party_model"
        printf '    export ANTHROPIC_DEFAULT_HAIKU_MODEL=%q\n' "$third_party_haiku_model"
        printf '    export ANTHROPIC_DEFAULT_SONNET_MODEL=%q\n' "$third_party_sonnet_model"
        printf '    export ANTHROPIC_DEFAULT_OPUS_MODEL=%q\n' "$third_party_opus_model"
        printf '    export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1\n'
        printf 'fi\n\n'

        printf '%s\n' \
            'claude_code_switch_inference_provider() {' \
            '    local new_provider="$1"' \
            '    if [ "$new_provider" != "anthropic" ] && [ "$new_provider" != "third-party" ]; then' \
            '        echo "usage: claude_code_switch_inference_provider anthropic|third-party" >&2' \
            '        return 1' \
            '    fi' \
            '    local bashrc="${HOME}/.bashrc"' \
            '    local begin="# >>> autonomous-agent-bootstrap AAB_CLAUDE_CODE_INFERENCE_PROVIDER >>>"' \
            '    local end="# <<< autonomous-agent-bootstrap AAB_CLAUDE_CODE_INFERENCE_PROVIDER <<<"' \
            '    if ! grep -qF "$begin" "$bashrc"; then' \
            '        echo "claude_code_switch_inference_provider: marker not found in $bashrc" >&2' \
            '        return 1' \
            '    fi' \
            '    local tmp' \
            '    tmp=$(mktemp) || return 1' \
            '    awk -v begin="$begin" -v end="$end" -v provider="$new_provider" '\''' \
            '        $0 == begin { in_block=1; print; print "AAB_CLAUDE_CODE_INFERENCE_PROVIDER=\"" provider "\""; next }' \
            '        $0 == end   { in_block=0; print; next }' \
            '        in_block    { next }' \
            '                    { print }' \
            '    '\'' "$bashrc" > "$tmp" || { rm -f "$tmp"; return 1; }' \
            '    mv "$tmp" "$bashrc"' \
            '    # shellcheck disable=SC1090' \
            '    . "$bashrc"' \
            '}'
        printf '%s\n' "${BASHRC_MARKER_END}"
    } >> "${BASHRC}"
    log "Wrote autonomous-agent-bootstrap block to ${BASHRC} (provider=${provider}, model=${model}, haiku=${haiku_model}, sonnet=${sonnet_model}, opus=${opus_model})."
}

# ---------------------------------------------------------------------------
# 10. Mirror the credential / config env vars into /etc/environment.
#
# ~/.bashrc only loads for interactive bash shells; `ssh user@host cmd`
# launches a non-interactive non-login shell that skips it entirely, and
# systemd services start with whatever env their unit file declares — so
# anything that needs ANTHROPIC_API_KEY, GH_TOKEN, ANTHROPIC_MODEL, etc.
# from one of those contexts has nothing to read.
#
# /etc/environment is the cross-shell mechanism on Linux: PAM's pam_env
# module loads it during session setup, including for ssh non-interactive
# remote-command sessions, console logins, and `su -`. It's a flat
# `KEY=VALUE` file (no shell expansion), exactly what's needed for the
# resolved-at-bootstrap-time provider config we already build for
# ~/.bashrc. systemd services that want the same values can reference
# the same file with `EnvironmentFile=/etc/environment`.
#
# Re-runs replace the managed block in place. Writing /etc/environment
# needs root; `update_etc_environment` follows the same warn-and-skip
# pattern as `ensure_gh` when passwordless sudo isn't available — the
# bootstrap finishes, ~/.bashrc still gets written, but non-interactive
# shells won't see the env vars until sudo is wired up and the bootstrap
# is re-run.
#
# The provider runtime-switch function in ~/.bashrc still only updates
# bashrc (interactive only). To make a switch visible to non-interactive
# shells, re-run bootstrap.bash with the new provider — that rewrites
# both the bashrc block and the /etc/environment block.
# ---------------------------------------------------------------------------
update_etc_environment() {
    if [ -n "$SUDO" ] && ! sudo -n true 2>/dev/null; then
        warn "Updating $ETC_ENV needs sudo and passwordless sudo is not available; skipping. Non-interactive shells (ssh remote command, systemd services) will not see AAB's env vars."
        return
    fi

    local provider="${AAB_CLAUDE_CODE_INFERENCE_PROVIDER:-anthropic}"
    if [ "$provider" != "anthropic" ] && [ "$provider" != "third-party" ]; then
        provider="anthropic"
    fi
    local model="${AAB_CLAUDE_CODE_MODEL:-$DEFAULT_CLAUDE_CODE_MODEL}"
    local haiku_model="${AAB_CLAUDE_CODE_HAIKU_MODEL:-$DEFAULT_CLAUDE_CODE_HAIKU_MODEL}"
    local sonnet_model="${AAB_CLAUDE_CODE_SONNET_MODEL:-$DEFAULT_CLAUDE_CODE_SONNET_MODEL}"
    local opus_model="${AAB_CLAUDE_CODE_OPUS_MODEL:-$DEFAULT_CLAUDE_CODE_OPUS_MODEL}"
    local third_party_prefix="${AAB_CLAUDE_CODE_MODEL_THIRD_PARTY_PREFIX:-}"

    local tmp
    tmp=$(mktemp)
    {
        # Carry over everything outside the previous managed block, if any.
        if [ -f "$ETC_ENV" ]; then
            awk -v begin="${ETC_ENV_MARKER_BEGIN}" -v end="${ETC_ENV_MARKER_END}" '
                $0 == begin { skip=1; next }
                $0 == end   { skip=0; next }
                !skip { print }
            ' "$ETC_ENV"
        fi

        # Drop any trailing blank lines from the carry-over so re-runs do not
        # accumulate them; the explicit '\n' before BEGIN gives one separator.
        printf '\n%s\n' "${ETC_ENV_MARKER_BEGIN}"
        printf 'AAB_CLAUDE_CODE_INFERENCE_PROVIDER="%s"\n' "$provider"
        printf 'CLAUDE_CODE_SANDBOXED="1"\n'
        if [ -n "${GH_TOKEN:-}" ]; then
            printf 'GH_TOKEN="%s"\n' "$GH_TOKEN"
        fi
        if [ "$provider" = "anthropic" ]; then
            if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
                printf 'ANTHROPIC_API_KEY="%s"\n' "$ANTHROPIC_API_KEY"
            fi
            printf 'ANTHROPIC_MODEL="%s"\n' "$model"
            printf 'ANTHROPIC_DEFAULT_HAIKU_MODEL="%s"\n'  "$haiku_model"
            printf 'ANTHROPIC_DEFAULT_SONNET_MODEL="%s"\n' "$sonnet_model"
            printf 'ANTHROPIC_DEFAULT_OPUS_MODEL="%s"\n'   "$opus_model"
        else
            if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
                printf 'ANTHROPIC_BASE_URL="%s"\n' "$ANTHROPIC_BASE_URL"
            fi
            if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
                printf 'ANTHROPIC_AUTH_TOKEN="%s"\n' "$ANTHROPIC_AUTH_TOKEN"
            fi
            printf 'ANTHROPIC_MODEL="%s"\n'                "${third_party_prefix}${model}"
            printf 'ANTHROPIC_DEFAULT_HAIKU_MODEL="%s"\n'  "${third_party_prefix}${haiku_model}"
            printf 'ANTHROPIC_DEFAULT_SONNET_MODEL="%s"\n' "${third_party_prefix}${sonnet_model}"
            printf 'ANTHROPIC_DEFAULT_OPUS_MODEL="%s"\n'   "${third_party_prefix}${opus_model}"
            printf 'CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS="1"\n'
        fi
        printf '%s\n' "${ETC_ENV_MARKER_END}"
    } > "$tmp"

    # `install` is atomic and sets mode in one syscall, so a partial write
    # or a stale 0600 from mktemp does not show up in /etc/environment
    # mid-rewrite. Owner stays root: when SUDO=sudo (the default for non-
    # root callers) the install runs under sudo's elevated EUID and writes
    # the file as root by default; -o/-g flags would just duplicate that.
    $SUDO install -m 0644 "$tmp" "$ETC_ENV"
    rm -f "$tmp"
    log "Wrote autonomous-agent-bootstrap block to $ETC_ENV (provider=$provider)."
}

# ---------------------------------------------------------------------------
# Optional config input (positional arg or stdin).
#
# main() picks one of three modes, in order:
#   1. positional path: `bash bootstrap.bash /path/to/aab.conf` — load_config_file
#      reads the file at the supplied path.
#   2. stdin pipe:      `bash bootstrap.bash <<EOF ... EOF` (or any non-TTY
#      stdin shape) — load_config_stdin reads stdin into a temp file and loads
#      that. The temp file is removed before main() returns.
#   3. neither:         the script runs with whatever env vars the shell
#      already has, no config-file step.
#
# In modes 1 and 2 the config text is sourced via `set -a; . <path>; set +a`.
# That's the standard bash idiom for KEY=VALUE files and gives the file
# access to the full shell language: `${VAR:-default}` expansions, `$(cmd)`
# substitutions, multi-line strings, comments, etc. Values containing shell
# metacharacters (`&`, `|`, `;`, `$`, etc.) need to be quoted; bare quoted
# `KEY=value` lines need no escaping.
#
# Caller-supplied env vars beat file values: load_config_{file,stdin}
# snapshot the exported environment before sourcing and replay it after, so
# a one-off `FOO=override bash bootstrap.bash /path/to/conf` debug invocation
# wins over whatever the file said. An explicitly-empty `FOO= bash …`
# counts as set and also wins (file cannot force-unset what the shell
# explicitly set).
# ---------------------------------------------------------------------------
load_config_file() {
    local f="$1"
    if [ ! -r "$f" ]; then
        warn "Config file '$f' not found or not readable."
        exit 1
    fi
    log "Loading config from $f (env vars already set in the shell take precedence)."
    _source_config "$f"
}

load_config_stdin() {
    local tmp
    tmp=$(mktemp)
    cat > "$tmp"
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        return 0
    fi
    log "Loading config from stdin (env vars already set in the shell take precedence)."
    _source_config "$tmp"
    rm -f "$tmp"
}

# Source the config at <path> with auto-export, preserving caller-supplied env
# vars. `declare -px` snapshots every exported variable; we strip the
# readonly entries (re-eval'ing those would error) and rewrite `declare -x`
# as `export` so the snapshot restores at the calling shell's scope rather
# than going out of scope when the function returns.
_source_config() {
    local src="$1" snapshot
    snapshot=$(declare -px | grep -v '^declare -[a-z]*r' | sed 's/^declare -x /export /')
    set -a
    # shellcheck source=/dev/null
    . "$src"
    set +a
    eval "$snapshot"
}

main() {
    if [ -n "${1:-}" ]; then
        load_config_file "$1"
    elif [ ! -t 0 ]; then
        load_config_stdin
    fi
    install_base_deps
    install_claude
    install_brev
    ensure_gh
    write_settings
    skip_onboarding
    skip_brev_onboarding
    configure_git
    install_auth_ssh_key
    install_signing_ssh_key
    install_claude_code_plugins
    update_bashrc
    update_etc_environment
    log "Done. Open a new shell (or 'source ~/.bashrc') so the PATH / alias take effect."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
