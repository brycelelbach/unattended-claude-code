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
assert d["model"].startswith("claude-"), d
allow = d["permissions"]["allow"]
for op in ("Edit", "Write", "Read"):
    assert f"{op}({home}/.claude/**)" in allow, (op, allow)
    assert f"{op}({home}/.claude.json)" in allow, (op, allow)
PY
pass "settings.json written with unattended-mode defaults."

# 2. .claude.json has onboarding flag set.
[ -f "$CLAUDE_JSON" ] || fail ".claude.json not written."
python3 - "$CLAUDE_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["hasCompletedOnboarding"] is True, d
PY
pass ".claude.json has hasCompletedOnboarding=true."

# 3. Brev onboarding file is valid JSON.
[ -f "$BREV_ONBOARDING" ] || fail "brev onboarding_step.json not written."
python3 -c "import json; json.load(open('$BREV_ONBOARDING'))"
pass "brev onboarding_step.json is valid JSON."

# 4. Managed bashrc block is present exactly once.
grep -q '# >>> autonomous-agent-bootstrap >>>' "$BASHRC" \
    || fail "bashrc begin marker missing."
grep -q '# <<< autonomous-agent-bootstrap <<<' "$BASHRC" \
    || fail "bashrc end marker missing."
begin_count=$(grep -c '^# >>> autonomous-agent-bootstrap >>>$' "$BASHRC")
end_count=$(grep -c '^# <<< autonomous-agent-bootstrap <<<$' "$BASHRC")
[ "$begin_count" -eq 1 ] || fail "Expected 1 bashrc begin marker, got $begin_count."
[ "$end_count" -eq 1 ]   || fail "Expected 1 bashrc end marker, got $end_count."
pass "bashrc managed block present exactly once."

# 5. Provider-switch function is defined in the bashrc block.
grep -q 'claude_code_switch_inference_provider()' "$BASHRC" \
    || fail "Provider-switch function not written."
pass "claude_code_switch_inference_provider function written."

# 6. Inner provider marker block is present with the expected value.
grep -q 'AAB_CLAUDE_CODE_INFERENCE_PROVIDER=' "$BASHRC" \
    || fail "Provider variable not written."
pass "AAB_CLAUDE_CODE_INFERENCE_PROVIDER set in bashrc."

# 6b. Both branches export every ANTHROPIC_DEFAULT_*_MODEL so each model
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

# 7. The bashrc block sources cleanly.
bash -n "$BASHRC" || fail "bashrc has syntax errors."
pass "bashrc parses cleanly."

# 8. The binaries the bootstrap installed are on PATH (via ~/.local/bin).
export PATH="$HOME/.local/bin:$PATH"
command -v claude >/dev/null 2>&1 || fail "claude not on PATH after bootstrap."
pass "claude binary installed and on PATH."
command -v brev   >/dev/null 2>&1 || fail "brev not on PATH after bootstrap."
pass "brev binary installed and on PATH."
command -v gh     >/dev/null 2>&1 || fail "gh not on PATH after bootstrap."
pass "gh binary installed."

# 9. git identity was configured.
[ "$(git config --global user.name)"  = "CI Bot" ]         || fail "git user.name not set."
[ "$(git config --global user.email)" = "ci@example.com" ] || fail "git user.email not set."
pass "git identity configured."

# 10. gh credential helper is registered for github.com.
gh_helper=$(git config --global --get 'credential.https://github.com.helper' || true)
[ "$gh_helper" = '!gh auth git-credential' ] \
    || fail "gh credential helper not registered (got: '$gh_helper')."
pass "gh registered as github.com credential helper."

# 11. /etc/environment carries the same provider / model / token state
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
pass "$ETC_ENV managed block present exactly once with provider / model state."

echo "All e2e assertions passed."
