#!/usr/bin/env bash
# Bootstrap a fresh, non-interactive Claude Code install on a Linux host.
#
# Does the following, idempotently:
#   1. Installs Claude Code (native installer) if not already present.
#   2. Installs the gh CLI from the official apt/dnf repo (system-wide;
#      needs sudo).
#   3. Writes ~/.claude/settings.json with unattended-mode defaults
#      (bypassPermissions, sandboxed, max effort, opus-4-7).
#   4. Pre-populates ~/.claude.json with hasCompletedOnboarding=true so the
#      first `claude` launch skips the theme / color-scheme wizard, and —
#      if ANTHROPIC_API_KEY is set — pre-approves that key so the CLI
#      doesn't prompt for approval on first use either.
#   5. Configures git: user.name, user.email (from env vars), and registers
#      gh as the github.com credential helper so `git clone` / `push` reuse
#      the gh CLI's stored token.
#   6. Appends PATH / alias / env exports to ~/.bashrc (managed block) so
#      interactive shells pick up ~/.local/bin, run `claude` with
#      --dangerously-skip-permissions, and — if ANTHROPIC_API_KEY was set
#      at bootstrap time — export it for future shells.
#
# Optional env vars:
#   ANTHROPIC_API_KEY   Pre-approved in ~/.claude.json and exported from the
#                       ~/.bashrc managed block.
#   GH_TOKEN            Exported from the ~/.bashrc managed block. gh reads
#                       it from the environment directly, and the github.com
#                       credential helper we register below delegates to
#                       `gh auth git-credential`, so git clone/push reuse it.
#   GIT_AUTHOR_NAME       `git config --global user.name`.
#   GIT_AUTHOR_EMAIL      `git config --global user.email`.
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
BASHRC="${HOME}/.bashrc"
BASHRC_MARKER_BEGIN="# >>> unattended-claude-code bootstrap >>>"
BASHRC_MARKER_END="# <<< unattended-claude-code bootstrap <<<"

log() { printf '[bootstrap] %s\n' "$*"; }
warn() { printf '[bootstrap] WARN: %s\n' "$*" >&2; }

need_sudo() {
    if [ "$(id -u)" -eq 0 ]; then echo ""; else echo "sudo"; fi
}
SUDO=$(need_sudo)

# ---------------------------------------------------------------------------
# 1. Install Claude Code (native installer) if missing.
# ---------------------------------------------------------------------------
install_claude() {
    if command -v claude >/dev/null 2>&1; then
        log "claude already installed: $(command -v claude) ($(claude --version 2>&1 | head -1))"
        return
    fi
    if [[ -x "${HOME}/.local/bin/claude" ]]; then
        log "claude found at ~/.local/bin/claude but not on PATH yet; will be picked up after PATH update"
        return
    fi
    log "installing Claude Code via native installer..."
    curl -fsSL https://claude.ai/install.sh | bash
}

# ---------------------------------------------------------------------------
# 2. Install gh CLI from the official cli.github.com repo.
#
# Ubuntu / Debian ship an old gh that predates `gh auth token` and
# `gh auth git-credential`. We specifically want those so the git
# credential helper wired up in configure_git() below actually works.
# ---------------------------------------------------------------------------
ensure_gh() {
    if command -v gh >/dev/null 2>&1; then
        log "gh already installed: $(gh --version 2>&1 | head -1)"
        return
    fi
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
    elif command -v dnf >/dev/null 2>&1; then
        log "installing gh from cli.github.com dnf repo"
        $SUDO dnf install -y 'dnf-command(config-manager)' || true
        $SUDO dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
        $SUDO dnf install -y gh
    else
        warn "unknown package manager — skipping gh install. Install manually from https://cli.github.com/"
    fi
}

# ---------------------------------------------------------------------------
# 3. Write ~/.claude/settings.json.
# ---------------------------------------------------------------------------
write_settings() {
    mkdir -p "${CLAUDE_DIR}"
    if [[ -f "${SETTINGS_FILE}" ]]; then
        local backup="${SETTINGS_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
        cp "${SETTINGS_FILE}" "${backup}"
        log "backed up existing settings.json -> ${backup}"
    fi
    cat > "${SETTINGS_FILE}" <<'JSON'
{
  "model": "claude-opus-4-7",
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
    log "wrote ${SETTINGS_FILE}"
}

# ---------------------------------------------------------------------------
# 4. Skip the first-run onboarding (theme prompt) AND pre-approve the
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
# 5. Configure git: identity + gh as github.com credential helper.
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
# 6. Rewrite the unattended-mode block in ~/.bashrc.
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
        log "replaced existing unattended-claude-code block in ${BASHRC}"
    fi
    {
        printf '\n%s\n' "${BASHRC_MARKER_BEGIN}"
        cat <<'EOS'
# Sources env file created by the Claude Code native installer, ensures
# ~/.local/bin is on PATH, and makes every interactive 'claude' invocation
# skip the permission prompt so the agent can run unattended.
if [ -f "$HOME/.local/bin/env" ]; then
    . "$HOME/.local/bin/env"
fi
export PATH="$HOME/.local/bin:$PATH"
export CLAUDE_CODE_SANDBOXED=1
alias claude='claude --dangerously-skip-permissions'
EOS
        if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
            printf 'export ANTHROPIC_API_KEY=%q\n' "$ANTHROPIC_API_KEY"
        fi
        if [ -n "${GH_TOKEN:-}" ]; then
            printf 'export GH_TOKEN=%q\n' "$GH_TOKEN"
        fi
        printf '%s\n' "${BASHRC_MARKER_END}"
    } >> "${BASHRC}"
    log "wrote unattended-claude-code block to ${BASHRC}"
}

main() {
    install_claude
    ensure_gh
    write_settings
    skip_onboarding
    configure_git
    update_bashrc
    log "done. Open a new shell (or 'source ~/.bashrc') so the PATH / alias take effect."
}

main "$@"
