#!/usr/bin/env bash
#
# Post-bootstrap assertions. Assumes bootstrap.bash has just run under the
# current HOME. Exits non-zero on the first failure.

set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

CLAUDE_DIR="${HOME}/.claude"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"
CLAUDE_JSON="${HOME}/.claude.json"
CODEX_CONFIG="${HOME}/.codex/config.toml"
CODEX_AUTH="${HOME}/.codex/auth.json"
BREV_ONBOARDING="${HOME}/.brev/onboarding_step.json"
BASHRC="${HOME}/.bashrc"

# 1. settings.json is well-formed and has the expected shape.
[ -f "$SETTINGS_FILE" ] || fail "settings.json not written."
python3 - "$SETTINGS_FILE" "$HOME" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
home = sys.argv[2]
assert d["permissions"]["defaultMode"] == "bypassPermissions", d
assert d["skipDangerousModePermissionPrompt"] is True, d
assert d["env"]["CLAUDE_CODE_SANDBOXED"] == "1", d
assert d["effortLevel"] == "max", d
assert d["env"]["CLAUDE_CODE_EFFORT_LEVEL"] == "max", d
assert d["model"].startswith("claude-"), d
assert d["extraKnownMarketplaces"]["robobryce-agitentic"]["source"]["repo"] == "brycelelbach/agitentic", d
assert d["enabledPlugins"]["agitentic@robobryce-agitentic"] is True, d
allow = d["permissions"]["allow"]
for op in ("Edit", "Write", "Read"):
    assert f"{op}({home}/.claude/**)" in allow, (op, allow)
    assert f"{op}({home}/.claude.json)" in allow, (op, allow)
PY
pass "settings.json written with unattended-mode defaults."

# 2. config.toml is present and puts Codex in unattended yolo mode.
[ -f "$CODEX_CONFIG" ] || fail "Codex config.toml not written."
expected_codex_effort="${AAB_CODEX_EFFORT:-xhigh}"
grep -q '^approval_policy = "never"$' "$CODEX_CONFIG" \
    || fail "Codex approval_policy is not never."
grep -q '^sandbox_mode = "danger-full-access"$' "$CODEX_CONFIG" \
    || fail "Codex sandbox_mode is not danger-full-access."
grep -q "^model_reasoning_effort = \"${expected_codex_effort}\"$" "$CODEX_CONFIG" \
    || fail "Codex reasoning effort is not ${expected_codex_effort}."
grep -q '^hide_full_access_warning = true$' "$CODEX_CONFIG" \
    || fail "Codex full-access warning acknowledgement not written."
grep -q '^inherit = "all"$' "$CODEX_CONFIG" \
    || fail "Codex shell env inheritance is not all."
grep -q '^ignore_default_excludes = true$' "$CODEX_CONFIG" \
    || fail "Codex shell env token inheritance is not enabled."
grep -qF "[projects.\"$HOME\"]" "$CODEX_CONFIG" \
    || fail "Codex HOME project trust entry missing."
pass "Codex config.toml written with unattended yolo-mode defaults."

# 3. .claude.json has onboarding flag set.
[ -f "$CLAUDE_JSON" ] || fail ".claude.json not written."
python3 - "$CLAUDE_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["hasCompletedOnboarding"] is True, d
PY
pass ".claude.json has hasCompletedOnboarding=true."

# 4. Brev onboarding file is valid JSON.
[ -f "$BREV_ONBOARDING" ] || fail "brev onboarding_step.json not written."
python3 -c "import json; json.load(open('$BREV_ONBOARDING'))"
pass "brev onboarding_step.json is valid JSON."

# 5. Managed bashrc block is present exactly once.
grep -q '# >>> autonomous-agent-bootstrap >>>' "$BASHRC" \
    || fail "bashrc begin marker missing."
grep -q '# <<< autonomous-agent-bootstrap <<<' "$BASHRC" \
    || fail "bashrc end marker missing."
begin_count=$(grep -c '^# >>> autonomous-agent-bootstrap >>>$' "$BASHRC")
end_count=$(grep -c '^# <<< autonomous-agent-bootstrap <<<$' "$BASHRC")
[ "$begin_count" -eq 1 ] || fail "Expected 1 bashrc begin marker, got $begin_count."
[ "$end_count" -eq 1 ]   || fail "Expected 1 bashrc end marker, got $end_count."
pass "bashrc managed block present exactly once."

# 6. Provider-switch function is defined in the bashrc block.
grep -q 'claude_code_switch_inference_provider()' "$BASHRC" \
    || fail "Provider-switch function not written."
pass "claude_code_switch_inference_provider function written."

# 7. Codex yolo alias is defined in the bashrc block.
grep -q "alias codex='codex --dangerously-bypass-approvals-and-sandbox'" "$BASHRC" \
    || fail "Codex yolo alias not written."
pass "Codex yolo alias written."

# 7b. Codex first-party API key exports are present when configured.
if [ -n "${AAB_CODEX_FIRST_PARTY_API_KEY:-}" ]; then
    grep -q '^export AAB_CODEX_FIRST_PARTY_API_KEY=' "$BASHRC" \
        || fail "AAB_CODEX_FIRST_PARTY_API_KEY export not written."
    grep -q '^export OPENAI_API_KEY=' "$BASHRC" \
        || fail "OPENAI_API_KEY export derived from AAB_CODEX_FIRST_PARTY_API_KEY not written."
    pass "Codex first-party API key exports written."
fi
if [ -n "${AAB_BREV_API_KEY:-}" ]; then
    grep -q '^export AAB_BREV_API_KEY=' "$BASHRC" \
        || fail "AAB_BREV_API_KEY export not written."
    grep -q '^export AAB_BREV_ORG_ID=' "$BASHRC" \
        || fail "AAB_BREV_ORG_ID export not written."
    pass "Brev API-key auth exports written."
fi

# 8. Inner provider marker block is present with the expected value.
grep -q 'AAB_CLAUDE_CODE_INFERENCE_PROVIDER=' "$BASHRC" \
    || fail "Provider variable not written."
pass "AAB_CLAUDE_CODE_INFERENCE_PROVIDER set in bashrc."

# 8b. Both branches export every ANTHROPIC_DEFAULT_*_MODEL so each model
# tier (the haiku used for background tasks like web search, the sonnet
# and opus available via /model swaps) resolves under whichever provider
# is active.
for tier in HAIKU SONNET OPUS; do
    var="ANTHROPIC_DEFAULT_${tier}_MODEL"
    count=$(grep -c "export ${var}=" "$BASHRC" || true)
    [ "$count" -eq 2 ] \
        || fail "Expected 2 ${var} exports, got $count."
done
pass "ANTHROPIC_DEFAULT_{HAIKU,SONNET,OPUS}_MODEL exported in both provider branches."

# 8c. DEBUG_SDK=1 is exported (provider-agnostic) so Claude Code writes
# its debug logs to ~/.claude/debug/<uuid>.txt for every invocation.
grep -q 'export DEBUG_SDK=1' "$BASHRC" \
    || fail "DEBUG_SDK=1 export missing from bashrc managed block."
pass "DEBUG_SDK=1 exported (claude debug logging on)."

# 8d. CLAUDE_CODE_EFFORT_LEVEL mirrors AAB_CLAUDE_CODE_EFFORT, defaulting
# to max so non-interactive launches keep the same effort setting.
grep -q 'export CLAUDE_CODE_EFFORT_LEVEL=max' "$BASHRC" \
    || fail "CLAUDE_CODE_EFFORT_LEVEL=max export missing from bashrc managed block."
pass "CLAUDE_CODE_EFFORT_LEVEL=max exported."

# 9. The bashrc block sources cleanly.
bash -n "$BASHRC" || fail "bashrc has syntax errors."
pass "bashrc parses cleanly."

# 10. The binaries the bootstrap installed are on PATH (via ~/.local/bin).
export PATH="$HOME/.local/bin:$PATH"
command -v claude >/dev/null 2>&1 || fail "claude not on PATH after bootstrap."
pass "claude binary installed and on PATH."
claude_plugins=$(claude plugin list 2>&1) || fail "claude plugin list failed."
case "$claude_plugins" in
    *"agitentic@robobryce-agitentic"*) ;;
    *) fail "Claude Code agitentic plugin not installed." ;;
esac
pass "Claude Code agent plugins installed."
command -v codex  >/dev/null 2>&1 || fail "codex not on PATH after bootstrap."
codex --version >/dev/null 2>&1 || fail "codex binary does not run."
pass "codex binary installed and runnable."
codex_plugins=$(codex plugin list 2>&1) || fail "codex plugin list failed."
case "$codex_plugins" in
    *"agitentic@robobryce-agitentic"*) ;;
    *) fail "Codex agitentic plugin not installed." ;;
esac
pass "Codex agent plugins installed."
if [ -n "${AAB_CODEX_FIRST_PARTY_API_KEY:-}" ]; then
    [ -f "$CODEX_AUTH" ] || fail "Codex auth.json not written."
    AAB_EXPECTED_CODEX_API_KEY="$AAB_CODEX_FIRST_PARTY_API_KEY" \
        python3 - "$CODEX_AUTH" <<'PY'
import json
import os
import sys
with open(sys.argv[1]) as f:
    data = json.load(f)
if data.get("auth_mode") != "apikey":
    raise AssertionError("Codex auth_mode is not apikey.")
if data.get("OPENAI_API_KEY") != os.environ["AAB_EXPECTED_CODEX_API_KEY"]:
    raise AssertionError("Codex auth API key does not match AAB_CODEX_FIRST_PARTY_API_KEY.")
PY
    codex_login_status=$(codex login status 2>&1)
    case "$codex_login_status" in
        *"Logged in using an API key"*) ;;
        *) fail "Codex login status does not report API-key auth." ;;
    esac
    pass "Codex first-party API-key auth configured."
fi
command -v brev   >/dev/null 2>&1 || fail "brev not on PATH after bootstrap."
pass "brev binary installed and on PATH."
if [ -n "${AAB_BREV_API_KEY:-}" ] || [ -n "${AAB_BREV_ORG_ID:-}" ]; then
    [ -n "${AAB_BREV_API_KEY:-}" ] || fail "AAB_BREV_API_KEY missing while AAB_BREV_ORG_ID is set."
    [ -n "${AAB_BREV_ORG_ID:-}" ] || fail "AAB_BREV_ORG_ID missing while AAB_BREV_API_KEY is set."
    [ -f "$HOME/.brev/credentials.json" ] || fail "Brev credentials.json not written."
    brev ls >/dev/null 2>&1 || fail "brev ls failed with API-key auth."
    pass "Brev API-key auth configured."
fi
command -v gh     >/dev/null 2>&1 || fail "gh not on PATH after bootstrap."
pass "gh binary installed."

# 11. git identity was configured.
[ "$(git config --global user.name)"  = "CI Bot" ]         || fail "git user.name not set."
[ "$(git config --global user.email)" = "ci@example.com" ] || fail "git user.email not set."
pass "git identity configured."

# 12. gh credential helper is registered for github.com.
gh_helper=$(git config --global --get 'credential.https://github.com.helper' || true)
[ "$gh_helper" = '!gh auth git-credential' ] \
    || fail "gh credential helper not registered (got: '$gh_helper')."
pass "gh registered as github.com credential helper."

# 13. /etc/environment carries the same provider / model / token state
# that ~/.bashrc does, so non-interactive shells (ssh remote command,
# systemd EnvironmentFile=, …) see the env vars too.
ETC_ENV=/etc/environment
if [ ! -r "$ETC_ENV" ]; then
    fail "$ETC_ENV not readable; non-interactive shells cannot pick up AAB env vars."
fi
grep -q '^# >>> autonomous-agent-bootstrap >>>$' "$ETC_ENV" \
    || fail "$ETC_ENV begin marker missing."
grep -q '^# <<< autonomous-agent-bootstrap <<<$' "$ETC_ENV" \
    || fail "$ETC_ENV end marker missing."
etc_begin=$(grep -c '^# >>> autonomous-agent-bootstrap >>>$' "$ETC_ENV")
etc_end=$(grep -c '^# <<< autonomous-agent-bootstrap <<<$' "$ETC_ENV")
[ "$etc_begin" -eq 1 ] || fail "Expected 1 $ETC_ENV begin marker, got $etc_begin."
[ "$etc_end"   -eq 1 ] || fail "Expected 1 $ETC_ENV end marker, got $etc_end."
grep -q '^AAB_CLAUDE_CODE_INFERENCE_PROVIDER=' "$ETC_ENV" \
    || fail "AAB_CLAUDE_CODE_INFERENCE_PROVIDER missing from $ETC_ENV."
grep -q '^ANTHROPIC_MODEL=' "$ETC_ENV" \
    || fail "ANTHROPIC_MODEL missing from $ETC_ENV."
grep -q '^CLAUDE_CODE_EFFORT_LEVEL="max"$' "$ETC_ENV" \
    || fail "CLAUDE_CODE_EFFORT_LEVEL missing from $ETC_ENV."
if [ -n "${AAB_CODEX_FIRST_PARTY_API_KEY:-}" ]; then
    grep -q '^AAB_CODEX_FIRST_PARTY_API_KEY=' "$ETC_ENV" \
        || fail "AAB_CODEX_FIRST_PARTY_API_KEY missing from $ETC_ENV."
    grep -q '^OPENAI_API_KEY=' "$ETC_ENV" \
        || fail "OPENAI_API_KEY missing from $ETC_ENV."
fi
if [ -n "${AAB_BREV_API_KEY:-}" ]; then
    grep -q '^AAB_BREV_API_KEY=' "$ETC_ENV" \
        || fail "AAB_BREV_API_KEY missing from $ETC_ENV."
    grep -q '^AAB_BREV_ORG_ID=' "$ETC_ENV" \
        || fail "AAB_BREV_ORG_ID missing from $ETC_ENV."
fi
pass "$ETC_ENV managed block present exactly once with provider / model state."

echo "All e2e assertions passed."
