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
#   8. Appends PATH / alias / env exports to ~/.bashrc (managed block) so
#      interactive shells pick up ~/.local/bin, run `claude` with
#      --dangerously-skip-permissions, and — if ANTHROPIC_API_KEY was set
#      at bootstrap time — export it for future shells.
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
#                       of Anthropic model names. Prepended to
#                       AAB_CLAUDE_CODE_MODEL in the third-party branch's
#                       ANTHROPIC_MODEL export (e.g. 'aws/anthropic/bedrock-'
#                       + 'claude-opus-4-7' = 'aws/anthropic/bedrock-claude-
#                       opus-4-7').
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

set -euo pipefail

CLAUDE_DIR="${HOME}/.claude"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"
CLAUDE_JSON="${HOME}/.claude.json"
BREV_DIR="${HOME}/.brev"
BREV_ONBOARDING="${BREV_DIR}/onboarding_step.json"
BASHRC="${HOME}/.bashrc"
BASHRC_MARKER_BEGIN="# >>> autonomous-agent-bootstrap >>>"
BASHRC_MARKER_END="# <<< autonomous-agent-bootstrap <<<"
DEFAULT_CLAUDE_CODE_MODEL="claude-opus-4-7"

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
        warn "missing base deps (${needed[*]}) and apt-get is not available; install them manually and re-run"
        return
    fi
    if [ -n "$SUDO" ] && ! sudo -n true 2>/dev/null; then
        warn "missing base deps (${needed[*]}) and passwordless sudo is not available; install them manually and re-run"
        return
    fi

    log "installing base deps: ${needed[*]}"
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -y
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${needed[@]}"
}

# ---------------------------------------------------------------------------
# 1. Install / upgrade Claude Code via the native installer.
# ---------------------------------------------------------------------------
install_claude() {
    log "installing / updating Claude Code via native installer..."
    curl -fsSL https://claude.ai/install.sh | bash
}

# ---------------------------------------------------------------------------
# 2. Install / upgrade the Brev CLI via the official install-latest.sh.
# ---------------------------------------------------------------------------
install_brev() {
    log "installing / updating Brev CLI via official installer..."
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
        warn "gh install needs sudo and passwordless sudo is not available; skipping"
        warn "install gh manually from https://cli.github.com/ and re-run"
        return
    fi
    if command -v apt-get >/dev/null 2>&1; then
        log "installing gh from cli.github.com apt repo"
        local keyring=/usr/share/keyrings/githubcli-archive-keyring.gpg
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            | $SUDO dd of="$keyring" status=none
        $SUDO chmod go+r "$keyring"
        echo "deb [arch=$(dpkg --print-architecture) signed-by=$keyring] https://cli.github.com/packages stable main" \
            | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null
        $SUDO apt-get update -y
        $SUDO apt-get install -y gh
    else
        warn "apt-get not found — skipping gh install. Install manually from https://cli.github.com/"
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
        log "backed up existing settings.json -> ${backup}"
    fi
    local model="${AAB_CLAUDE_CODE_MODEL:-$DEFAULT_CLAUDE_CODE_MODEL}"
    cat > "${SETTINGS_FILE}" <<JSON
{
  "model": "${model}",
  "effortLevel": "max",
  "permissions": {
    "defaultMode": "bypassPermissions"
  },
  "skipDangerousModePermissionPrompt": true,
  "env": {
    "CLAUDE_CODE_SANDBOXED": "1",
    "CLAUDE_CODE_EFFORT_LEVEL": "max"
  }
}
JSON
    log "wrote ${SETTINGS_FILE} (model=${model})"
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
    command -v python3 >/dev/null 2>&1 || { log "ERROR: python3 required to edit ~/.claude.json"; exit 1; }
    python3 - "${CLAUDE_JSON}" "${ANTHROPIC_API_KEY:-}" <<'PY'
import json, os, shutil, sys, time
path = sys.argv[1]
api_key = sys.argv[2] if len(sys.argv) > 2 else ""
data = {}
if os.path.exists(path):
    backup = f"{path}.bak.{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(path, backup)
    print(f"[bootstrap] backed up existing .claude.json -> {backup}")
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
    print(f"[bootstrap] pre-approved ANTHROPIC_API_KEY fingerprint ...{fp}")
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2)
print(f"[bootstrap] set hasCompletedOnboarding=true in {path}")
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
        log "backed up existing onboarding.json -> ${backup}"
    fi
    cat > "${BREV_ONBOARDING}" <<'JSON'
{"step": 1, "hasRunBrevShell": true, "hasRunBrevOpen": true}
JSON
    log "wrote ${BREV_ONBOARDING}"
}

# ---------------------------------------------------------------------------
# 7. Configure git: identity + gh as github.com credential helper.
# ---------------------------------------------------------------------------
configure_git() {
    if ! command -v git >/dev/null 2>&1; then
        warn "git not installed — skipping git configuration"
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
        log "registered gh as github.com credential helper"
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
    command -v python3 >/dev/null 2>&1 || { warn "python3 required for plugin install; skipping"; return; }
    local plugins_file="${AAB_CLAUDE_CODE_PLUGINS_FILE:-}"
    local plugins_url="${AAB_CLAUDE_CODE_PLUGINS_URL:-$PLUGINS_DEFAULT_URL}"
    local content=""
    if [ -n "$plugins_file" ] && [ -f "$plugins_file" ]; then
        content=$(cat "$plugins_file")
        log "reading plugin list from ${plugins_file}"
    elif content=$(curl -fsSL "$plugins_url" 2>/dev/null); then
        log "fetched plugin list from ${plugins_url}"
    else
        warn "could not read plugin list (file=${plugins_file:-unset}, url=${plugins_url}); skipping plugin install"
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
        log "plugin list is empty; skipping plugin install"
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
            log "could not fetch .claude-plugin/marketplace.json from ${repo} (private repo without access?); skipping"
            continue
        fi
        marketplace_name=$(printf '%s' "$marketplace_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))') || marketplace_name=""
        if [ -z "$marketplace_name" ]; then
            warn "${repo}/.claude-plugin/marketplace.json has no 'name'; skipping"
            continue
        fi
        plugin_names=$(printf '%s' "$marketplace_json" | python3 -c 'import json,sys; [print(p["name"]) for p in json.load(sys.stdin).get("plugins",[]) if p.get("name")]')
        if [ -z "$plugin_names" ]; then
            warn "${repo} marketplace lists no plugins; skipping"
            continue
        fi
        while IFS= read -r plugin_name; do
            [ -z "$plugin_name" ] && continue
            tuples+=("${repo}|${marketplace_name}|${plugin_name}")
        done <<< "$plugin_names"
    done

    if [ ${#tuples[@]} -eq 0 ]; then
        warn "no plugins resolved; skipping settings.json update"
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
    print(f"[bootstrap] enabled plugin {plugin}@{marketplace} from github {repo}")
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PY
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
        log "replaced existing autonomous-agent-bootstrap block in ${BASHRC}"
    fi

    local provider="${AAB_CLAUDE_CODE_INFERENCE_PROVIDER:-anthropic}"
    if [ "$provider" != "anthropic" ] && [ "$provider" != "third-party" ]; then
        warn "AAB_CLAUDE_CODE_INFERENCE_PROVIDER='${provider}' is not 'anthropic' or 'third-party'; defaulting to 'anthropic'"
        provider="anthropic"
    fi
    local model="${AAB_CLAUDE_CODE_MODEL:-$DEFAULT_CLAUDE_CODE_MODEL}"
    local third_party_prefix="${AAB_CLAUDE_CODE_MODEL_THIRD_PARTY_PREFIX:-}"
    local third_party_model="${third_party_prefix}${model}"

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
        printf 'else\n'
        printf '    unset ANTHROPIC_API_KEY\n'
        if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
            printf '    export ANTHROPIC_BASE_URL=%q\n' "$ANTHROPIC_BASE_URL"
        fi
        if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
            printf '    export ANTHROPIC_AUTH_TOKEN=%q\n' "$ANTHROPIC_AUTH_TOKEN"
        fi
        printf '    export ANTHROPIC_MODEL=%q\n' "$third_party_model"
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
    log "wrote autonomous-agent-bootstrap block to ${BASHRC} (provider=${provider}, model=${model})"
}

main() {
    install_base_deps
    install_claude
    install_brev
    ensure_gh
    write_settings
    skip_onboarding
    skip_brev_onboarding
    configure_git
    install_claude_code_plugins
    update_bashrc
    log "done. Open a new shell (or 'source ~/.bashrc') so the PATH / alias take effect."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
