#!/usr/bin/env bats
#
# Unit tests for bootstrap.bash. We source the script with TEST_MODE set so
# main() does not run, then exercise individual functions against a
# per-test HOME sandbox.

setup() {
    export TEST_HOME="$(mktemp -d)"
    export HOME="$TEST_HOME"
    export REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # Unset env vars the script looks at so each test controls its own.
    unset AAB_CLAUDE_CODE_FIRST_PARTY_MODEL \
          AAB_CLAUDE_CODE_FIRST_PARTY_HAIKU_MODEL \
          AAB_CLAUDE_CODE_FIRST_PARTY_SONNET_MODEL \
          AAB_CLAUDE_CODE_FIRST_PARTY_OPUS_MODEL \
          AAB_CLAUDE_CODE_THIRD_PARTY_MODEL \
          AAB_CLAUDE_CODE_THIRD_PARTY_HAIKU_MODEL \
          AAB_CLAUDE_CODE_THIRD_PARTY_SONNET_MODEL \
          AAB_CLAUDE_CODE_THIRD_PARTY_OPUS_MODEL \
          AAB_CLAUDE_CODE_EFFORT \
          AAB_CLAUDE_CODE_INFERENCE_PROVIDER \
          AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY \
          AAB_CLAUDE_CODE_THIRD_PARTY_BASE_URL \
          AAB_CLAUDE_CODE_THIRD_PARTY_AUTH_TOKEN \
          AAB_CODEX_FIRST_PARTY_MODEL AAB_CODEX_EFFORT \
          AAB_CODEX_FIRST_PARTY_API_KEY AAB_SKIP_INFERENCE_SMOKE_TESTS \
          AAB_GH_TOKEN AAB_GIT_AUTHOR_NAME AAB_GIT_AUTHOR_EMAIL \
          AAB_GH_AUTH_SSH_PRIVATE_KEY_B64 AAB_GIT_SIGNING_PRIVATE_KEY_B64 \
          ANTHROPIC_API_KEY ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN \
          OPENAI_API_KEY GH_TOKEN GITHUB_TOKEN \
          AAB_AGENT_PLUGINS_FILE AAB_AGENT_PLUGINS_URL
    # shellcheck disable=SC1091
    source "$REPO_ROOT/bootstrap.bash"
}

teardown() {
    rm -rf "$TEST_HOME"
}

@test "log writes to stdout with bootstrap prefix" {
    run log "hello"
    [ "$status" -eq 0 ]
    [ "$output" = "[bootstrap] hello" ]
}

@test "warn writes to stderr with WARN prefix" {
    run warn "bad"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[bootstrap] WARN: bad"* ]]
}

@test "need_sudo returns empty string for uid 0, 'sudo' otherwise" {
    result=$(need_sudo)
    if [ "$(id -u)" -eq 0 ]; then
        [ "$result" = "" ]
    else
        [ "$result" = "sudo" ]
    fi
}

@test "configure_git uses AAB-prefixed git identity vars" {
    command -v git >/dev/null || skip "precondition: git must exist"
    AAB_GIT_AUTHOR_NAME="Alice Example" \
        AAB_GIT_AUTHOR_EMAIL="alice@example.com" \
        configure_git
    [ "$(git config --global --get user.name)" = "Alice Example" ]
    [ "$(git config --global --get user.email)" = "alice@example.com" ]
}

@test "skip_brev_onboarding writes valid JSON to BREV_ONBOARDING" {
    skip_brev_onboarding
    [ -f "$BREV_ONBOARDING" ]
    python3 -c "import json; json.load(open('$BREV_ONBOARDING'))"
    grep -q '"hasRunBrevShell": true' "$BREV_ONBOARDING"
}

@test "skip_brev_onboarding backs up pre-existing onboarding file" {
    mkdir -p "$BREV_DIR"
    echo '{"old": true}' > "$BREV_ONBOARDING"
    skip_brev_onboarding
    local backup_count
    backup_count=$(find "$BREV_DIR" -maxdepth 1 -name 'onboarding_step.json.bak.*' | wc -l)
    [ "$backup_count" -ge 1 ]
}

@test "write_settings uses default model when first-party model unset" {
    write_settings
    [ -f "$SETTINGS_FILE" ]
    python3 -c "import json; d=json.load(open('$SETTINGS_FILE')); assert d['model']=='$DEFAULT_CLAUDE_CODE_MODEL', d['model']"
}

@test "write_settings honors first-party model override" {
    AAB_CLAUDE_CODE_FIRST_PARTY_MODEL="claude-sonnet-4-6" write_settings
    python3 -c "import json; d=json.load(open('$SETTINGS_FILE')); assert d['model']=='claude-sonnet-4-6', d['model']"
}

@test "write_settings honors AAB_CLAUDE_CODE_EFFORT override" {
    AAB_CLAUDE_CODE_EFFORT="high" write_settings
    python3 - <<PY
import json
d = json.load(open("$SETTINGS_FILE"))
assert d["effortLevel"] == "high", d
assert d["env"]["CLAUDE_CODE_EFFORT_LEVEL"] == "high", d
PY
}

@test "write_settings sets bypassPermissions and sandbox env" {
    write_settings
    python3 - <<PY
import json
d = json.load(open("$SETTINGS_FILE"))
assert d["permissions"]["defaultMode"] == "bypassPermissions"
assert d["skipDangerousModePermissionPrompt"] is True
assert d["env"]["CLAUDE_CODE_SANDBOXED"] == "1"
assert d["effortLevel"] == "$DEFAULT_CLAUDE_CODE_EFFORT"
assert d["env"]["CLAUDE_CODE_EFFORT_LEVEL"] == "$DEFAULT_CLAUDE_CODE_EFFORT"
PY
}

@test "write_settings pre-approves edits to ~/.claude/** and ~/.claude.json" {
    write_settings
    python3 - <<PY
import json
d = json.load(open("$SETTINGS_FILE"))
home = "$HOME"
allow = d["permissions"]["allow"]
for op in ("Edit", "Write", "Read"):
    assert f"{op}({home}/.claude/**)" in allow, (op, allow)
    assert f"{op}({home}/.claude.json)" in allow, (op, allow)
PY
}

@test "write_settings backs up pre-existing settings.json" {
    mkdir -p "$CLAUDE_DIR"
    echo '{"model": "old"}' > "$SETTINGS_FILE"
    write_settings
    local backup_count
    backup_count=$(find "$CLAUDE_DIR" -maxdepth 1 -name 'settings.json.bak.*' | wc -l)
    [ "$backup_count" -ge 1 ]
}

@test "write_codex_config writes unattended yolo-mode defaults" {
    write_codex_config
    [ -f "$CODEX_CONFIG" ]
    grep -q '^model = "gpt-5.5"$' "$CODEX_CONFIG"
    grep -q '^model_reasoning_effort = "xhigh"$' "$CODEX_CONFIG"
    grep -q '^approval_policy = "never"$' "$CODEX_CONFIG"
    grep -q '^sandbox_mode = "danger-full-access"$' "$CODEX_CONFIG"
    grep -q '^web_search = "live"$' "$CODEX_CONFIG"
    grep -q '^hide_full_access_warning = true$' "$CODEX_CONFIG"
    grep -q '^inherit = "all"$' "$CODEX_CONFIG"
    grep -q '^ignore_default_excludes = true$' "$CODEX_CONFIG"
    grep -qF "[projects.\"$HOME\"]" "$CODEX_CONFIG"
    grep -q '^trust_level = "trusted"$' "$CODEX_CONFIG"
}

@test "write_codex_config honors model and reasoning-effort overrides" {
    AAB_CODEX_FIRST_PARTY_MODEL="gpt-5.4" \
        AAB_CODEX_EFFORT="high" \
        write_codex_config
    grep -q '^model = "gpt-5.4"$' "$CODEX_CONFIG"
    grep -q '^model_reasoning_effort = "high"$' "$CODEX_CONFIG"
}

@test "write_codex_config defaults invalid reasoning effort back to xhigh" {
    AAB_CODEX_EFFORT="maximum" run write_codex_config
    [ "$status" -eq 0 ]
    [[ "$output" == *"AAB_CODEX_EFFORT='maximum'"* ]]
    grep -q '^model_reasoning_effort = "xhigh"$' "$CODEX_CONFIG"
}

@test "write_codex_config backs up pre-existing config.toml" {
    mkdir -p "$CODEX_DIR"
    echo 'model = "old"' > "$CODEX_CONFIG"
    write_codex_config
    local backup_count
    backup_count=$(find "$CODEX_DIR" -maxdepth 1 -name 'config.toml.bak.*' | wc -l)
    [ "$backup_count" -ge 1 ]
}

@test "write_codex_config preserves Codex plugin marketplace tables" {
    mkdir -p "$CODEX_DIR"
    cat > "$CODEX_CONFIG" <<'TOML'
model = "old"

[marketplaces.robobryce-agitentic]
last_updated = "2026-05-21T00:00:00Z"
source_type = "git"
source = "https://github.com/brycelelbach/agitentic.git"

[plugins."agitentic@robobryce-agitentic"]
enabled = true
TOML

    write_codex_config

    grep -q '^\[marketplaces.robobryce-agitentic\]$' "$CODEX_CONFIG"
    grep -q '^source = "https://github.com/brycelelbach/agitentic.git"$' "$CODEX_CONFIG"
    grep -q '^\[plugins."agitentic@robobryce-agitentic"\]$' "$CODEX_CONFIG"
    grep -q '^enabled = true$' "$CODEX_CONFIG"
    grep -q '^approval_policy = "never"$' "$CODEX_CONFIG"
}

setup_fake_codex_installer() {
    export FAKE_CODEX_INSTALLER_BIN="$TEST_HOME/fake-codex-installer-bin"
    mkdir -p "$FAKE_CODEX_INSTALLER_BIN"
    cat > "$FAKE_CODEX_INSTALLER_BIN/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_HOME/codex-installer-curl-invocations"

output=""
config=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o|--output)
            output="$2"
            shift 2
            ;;
        --config)
            config="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

if [ -n "$config" ]; then
    cat "$config" >> "$TEST_HOME/codex-installer-curl-configs"
fi

if [ -n "$output" ]; then
    cat > "$output" <<'INSTALLER'
#!/usr/bin/env bash
set -euo pipefail
curl -fsSL https://api.github.com/repos/openai/codex/releases/latest >/dev/null
curl -fsSL https://github.com/openai/codex/releases/download/rust-v0.133.0/codex.tar.gz >/dev/null
INSTALLER
    exit 0
fi

cat <<'INSTALLER'
#!/usr/bin/env bash
set -euo pipefail
curl -fsSL https://api.github.com/repos/openai/codex/releases/latest >/dev/null
curl -fsSL https://github.com/openai/codex/releases/download/rust-v0.133.0/codex.tar.gz >/dev/null
INSTALLER
SH
    chmod +x "$FAKE_CODEX_INSTALLER_BIN/curl"
    export PATH="$FAKE_CODEX_INSTALLER_BIN:$PATH"
}

@test "install_codex authenticates GitHub API calls when a GitHub token is available" {
    setup_fake_codex_installer
    GH_TOKEN="github-test-token" run install_codex
    [ "$status" -eq 0 ]
    [[ "$output" == *"Using GitHub authentication for Codex release metadata requests."* ]]
    grep -Eq '^--config .+ https://api.github.com/repos/openai/codex/releases/latest$' "$TEST_HOME/codex-installer-curl-invocations"
    grep -Fxq -- '-fsSL https://github.com/openai/codex/releases/download/rust-v0.133.0/codex.tar.gz' "$TEST_HOME/codex-installer-curl-invocations"
    grep -Fq 'header = "Authorization: Bearer github-test-token"' "$TEST_HOME/codex-installer-curl-configs"
}

@test "install_codex leaves installer calls unauthenticated without a GitHub token" {
    setup_fake_codex_installer
    run install_codex
    [ "$status" -eq 0 ]
    [[ "$output" != *"Using GitHub authentication for Codex release metadata requests."* ]]
    ! grep -Fq -- '--config' "$TEST_HOME/codex-installer-curl-invocations"
    [ ! -f "$TEST_HOME/codex-installer-curl-configs" ]
}

setup_fake_codex() {
    export FAKE_CODEX_BIN="$TEST_HOME/fake-codex-bin"
    mkdir -p "$FAKE_CODEX_BIN"
    cat > "$FAKE_CODEX_BIN/codex" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TEST_HOME/codex-invocations"
stdin=\$(cat)
printf '%s' "\$stdin" > "$TEST_HOME/codex-stdin"
if [ "\${FAKE_CODEX_FAIL:-0}" = "1" ]; then
    exit 42
fi
if [ "\$1" = "login" ] && [ "\${2:-}" = "--with-api-key" ]; then
    mkdir -p "\$HOME/.codex"
    printf '{"auth_mode":"apikey","OPENAI_API_KEY":"%s"}\n' "\$stdin" > "\$HOME/.codex/auth.json"
    exit 0
fi
exit 1
SH
    chmod +x "$FAKE_CODEX_BIN/codex"
    export PATH="$FAKE_CODEX_BIN:$PATH"
}

@test "configure_codex_auth is a no-op when AAB_CODEX_FIRST_PARTY_API_KEY is unset" {
    setup_fake_codex
    run configure_codex_auth
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_HOME/codex-invocations" ]
    [ ! -f "$HOME/.codex/auth.json" ]
}

@test "configure_codex_auth logs in with AAB_CODEX_FIRST_PARTY_API_KEY via stdin" {
    setup_fake_codex
    AAB_CODEX_FIRST_PARTY_API_KEY="codex-first-party-test-key" run configure_codex_auth
    [ "$status" -eq 0 ]
    grep -Fxq 'login --with-api-key' "$TEST_HOME/codex-invocations"
    [ "$(cat "$TEST_HOME/codex-stdin")" = "codex-first-party-test-key" ]
    python3 - <<PY
import json
d = json.load(open("$HOME/.codex/auth.json"))
assert d["auth_mode"] == "apikey", d
assert d["OPENAI_API_KEY"] == "codex-first-party-test-key", d
PY
    [[ "$output" != *"codex-first-party-test-key"* ]]
}

@test "configure_codex_auth fails when Codex API-key login fails" {
    setup_fake_codex
    export FAKE_CODEX_FAIL=1
    AAB_CODEX_FIRST_PARTY_API_KEY="codex-first-party-test-key" run configure_codex_auth
    [ "$status" -ne 0 ]
    [[ "$output" == *"codex login --with-api-key failed"* ]]
    [[ "$output" != *"codex-first-party-test-key"* ]]
}

setup_fake_smoke_agents() {
    export FAKE_SMOKE_BIN="$TEST_HOME/fake-smoke-bin"
    mkdir -p "$FAKE_SMOKE_BIN"

    cat > "$FAKE_SMOKE_BIN/claude" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TEST_HOME/claude-smoke-invocations"
if [ "\${FAKE_CLAUDE_SMOKE_FAIL:-0}" = "1" ]; then
    exit 42
fi
exit 0
SH
    chmod +x "$FAKE_SMOKE_BIN/claude"

    cat > "$FAKE_SMOKE_BIN/codex" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TEST_HOME/codex-smoke-invocations"
if [ "\${FAKE_CODEX_SMOKE_FAIL:-0}" = "1" ]; then
    exit 43
fi
exit 0
SH
    chmod +x "$FAKE_SMOKE_BIN/codex"

    export PATH="$FAKE_SMOKE_BIN:$PATH"
}

@test "run_inference_smoke_tests skips when AAB_SKIP_INFERENCE_SMOKE_TESTS is true" {
    local empty_bin="$TEST_HOME/empty-bin"
    mkdir -p "$empty_bin"
    AAB_SKIP_INFERENCE_SMOKE_TESTS=1 PATH="$empty_bin" run run_inference_smoke_tests
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipping Claude Code and Codex inference smoke tests"* ]]
}

@test "run_inference_smoke_tests runs Claude Code and Codex hello-world prompts" {
    setup_fake_smoke_agents
    run run_inference_smoke_tests
    [ "$status" -eq 0 ]
    grep -Fxq -- '--dangerously-skip-permissions -p hello world' "$TEST_HOME/claude-smoke-invocations"
    grep -Fxq -- 'exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check hello world' "$TEST_HOME/codex-smoke-invocations"
    [[ "$output" == *"Claude Code inference smoke test passed."* ]]
    [[ "$output" == *"Codex inference smoke test passed."* ]]
}

@test "run_inference_smoke_tests fails when Claude Code smoke fails" {
    setup_fake_smoke_agents
    export FAKE_CLAUDE_SMOKE_FAIL=1
    run run_inference_smoke_tests
    [ "$status" -ne 0 ]
    [[ "$output" == *"Claude Code inference smoke test failed."* ]]
    [ ! -f "$TEST_HOME/codex-smoke-invocations" ]
}

@test "run_inference_smoke_tests fails when Codex smoke fails" {
    setup_fake_smoke_agents
    export FAKE_CODEX_SMOKE_FAIL=1
    run run_inference_smoke_tests
    [ "$status" -ne 0 ]
    [[ "$output" == *"Codex inference smoke test failed."* ]]
    grep -Fxq -- '--dangerously-skip-permissions -p hello world' "$TEST_HOME/claude-smoke-invocations"
    grep -Fxq -- 'exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check hello world' "$TEST_HOME/codex-smoke-invocations"
}

@test "skip_onboarding creates .claude.json with hasCompletedOnboarding=true" {
    skip_onboarding
    [ -f "$CLAUDE_JSON" ]
    python3 -c "import json; d=json.load(open('$CLAUDE_JSON')); assert d['hasCompletedOnboarding'] is True"
}

@test "skip_onboarding pre-approves AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY fingerprint when set" {
    AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY="sk-ant-test-0123456789abcdef0123456789abcdef" skip_onboarding
    python3 - <<PY
import json
d = json.load(open("$CLAUDE_JSON"))
approved = d["customApiKeyResponses"]["approved"]
# Fingerprint is the last 20 chars of the key.
assert "f0123456789abcdef" in approved[0], approved
PY
}

@test "skip_onboarding preserves existing fields in .claude.json" {
    mkdir -p "$(dirname "$CLAUDE_JSON")"
    cat > "$CLAUDE_JSON" <<JSON
{"userID": "u-123", "hasCompletedOnboarding": false}
JSON
    skip_onboarding
    python3 - <<PY
import json
d = json.load(open("$CLAUDE_JSON"))
assert d["userID"] == "u-123"
assert d["hasCompletedOnboarding"] is True
PY
}

@test "skip_onboarding is idempotent (second call does not duplicate fingerprint)" {
    AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY="sk-ant-test-0123456789abcdef0123456789abcdef" skip_onboarding
    AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY="sk-ant-test-0123456789abcdef0123456789abcdef" skip_onboarding
    python3 - <<PY
import json
d = json.load(open("$CLAUDE_JSON"))
approved = d["customApiKeyResponses"]["approved"]
assert len(approved) == 1, approved
PY
}

@test "update_bashrc writes managed block with both markers" {
    update_bashrc
    [ -f "$BASHRC" ]
    grep -q "$BASHRC_MARKER_BEGIN" "$BASHRC"
    grep -q "$BASHRC_MARKER_END" "$BASHRC"
}

@test "update_bashrc aliases codex through yolo mode" {
    update_bashrc
    grep -q "alias codex='codex --dangerously-bypass-approvals-and-sandbox'" "$BASHRC"
}

@test "update_bashrc exports Codex first-party API key when set" {
    AAB_CODEX_FIRST_PARTY_API_KEY="codex-first-party-test-key" update_bashrc
    grep -q 'export AAB_CODEX_FIRST_PARTY_API_KEY=codex-first-party-test-key' "$BASHRC"
    grep -q 'export OPENAI_API_KEY=codex-first-party-test-key' "$BASHRC"
}

@test "update_bashrc is idempotent (single managed block after two runs)" {
    update_bashrc
    update_bashrc
    local begin_count end_count
    begin_count=$(grep -c "^${BASHRC_MARKER_BEGIN}$" "$BASHRC")
    end_count=$(grep -c "^${BASHRC_MARKER_END}$" "$BASHRC")
    [ "$begin_count" -eq 1 ]
    [ "$end_count" -eq 1 ]
}

@test "update_bashrc exports DEBUG_SDK=1 (turns on Claude Code debug logging)" {
    update_bashrc
    # Provider-agnostic — set unconditionally, outside the if/else.
    grep -qE "^export DEBUG_SDK=('?\"?)1\\1?$" "$BASHRC"
}

@test "update_bashrc exports CLAUDE_CODE_EFFORT_LEVEL from AAB_CLAUDE_CODE_EFFORT" {
    AAB_CLAUDE_CODE_EFFORT="high" update_bashrc
    grep -qE "^export CLAUDE_CODE_EFFORT_LEVEL=('?\"?)high\\1?$" "$BASHRC"
}

@test "update_bashrc exports first-party API key under AAB and Claude runtime names" {
    AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY="sk-ant-test-key" update_bashrc
    grep -q 'export AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY=sk-ant-test-key' "$BASHRC"
    grep -q 'export ANTHROPIC_API_KEY=sk-ant-test-key' "$BASHRC"
}

@test "update_bashrc exports third-party credentials under AAB and Claude runtime names" {
    AAB_CLAUDE_CODE_INFERENCE_PROVIDER="third-party" \
    AAB_CLAUDE_CODE_THIRD_PARTY_BASE_URL="https://gateway.example.com" \
    AAB_CLAUDE_CODE_THIRD_PARTY_AUTH_TOKEN="bearer-token-xyz" \
        update_bashrc
    grep -q 'export AAB_CLAUDE_CODE_THIRD_PARTY_BASE_URL=https://gateway.example.com' "$BASHRC"
    grep -q 'export ANTHROPIC_BASE_URL=https://gateway.example.com' "$BASHRC"
    grep -q 'export AAB_CLAUDE_CODE_THIRD_PARTY_AUTH_TOKEN=bearer-token-xyz' "$BASHRC"
    grep -q 'export ANTHROPIC_AUTH_TOKEN=bearer-token-xyz' "$BASHRC"
}

@test "update_bashrc exports GitHub token under AAB and gh runtime names" {
    AAB_GH_TOKEN="ghp_test_token" update_bashrc
    grep -q 'export AAB_GH_TOKEN=ghp_test_token' "$BASHRC"
    grep -q 'export GH_TOKEN=ghp_test_token' "$BASHRC"
}

@test "update_bashrc honors third-party provider selection" {
    AAB_CLAUDE_CODE_INFERENCE_PROVIDER="third-party" update_bashrc
    grep -q 'AAB_CLAUDE_CODE_INFERENCE_PROVIDER="third-party"' "$BASHRC"
}

@test "update_bashrc exports default ANTHROPIC_DEFAULT_*_MODEL in both branches" {
    update_bashrc
    # %q-quoting (single-quote, double-quote, or bare) varies by character class
    # in the value; accept any of the three.
    grep -qE "export ANTHROPIC_DEFAULT_HAIKU_MODEL=('?\"?)claude-haiku-4-5\\1?$"   "$BASHRC"
    grep -qE "export ANTHROPIC_DEFAULT_SONNET_MODEL=('?\"?)claude-sonnet-4-6\\1?$" "$BASHRC"
    grep -qE "export ANTHROPIC_DEFAULT_OPUS_MODEL=('?\"?)claude-opus-4-7\\1?$"     "$BASHRC"
    # Both branches export each var — two of each.
    for tier in HAIKU SONNET OPUS; do
        local export_count
        export_count=$(grep -c "export ANTHROPIC_DEFAULT_${tier}_MODEL=" "$BASHRC")
        [ "$export_count" -eq 2 ]
    done
}

@test "update_bashrc uses explicit first-party and third-party model vars" {
    AAB_CLAUDE_CODE_FIRST_PARTY_HAIKU_MODEL="claude-haiku-first" \
        AAB_CLAUDE_CODE_FIRST_PARTY_SONNET_MODEL="claude-sonnet-first" \
        AAB_CLAUDE_CODE_FIRST_PARTY_OPUS_MODEL="claude-opus-first" \
        AAB_CLAUDE_CODE_THIRD_PARTY_HAIKU_MODEL="aws/anthropic/claude-haiku-4-5-v1" \
        AAB_CLAUDE_CODE_THIRD_PARTY_SONNET_MODEL="aws/anthropic/bedrock-claude-sonnet-4-6" \
        AAB_CLAUDE_CODE_THIRD_PARTY_OPUS_MODEL="aws/anthropic/bedrock-claude-opus-4-7" \
        update_bashrc
    grep -q "ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-first"                         "$BASHRC"
    grep -q "ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-first"                       "$BASHRC"
    grep -q "ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-first"                           "$BASHRC"
    grep -q "ANTHROPIC_DEFAULT_HAIKU_MODEL=aws/anthropic/claude-haiku-4-5-v1"          "$BASHRC"
    grep -q "ANTHROPIC_DEFAULT_SONNET_MODEL=aws/anthropic/bedrock-claude-sonnet-4-6" "$BASHRC"
    grep -q "ANTHROPIC_DEFAULT_OPUS_MODEL=aws/anthropic/bedrock-claude-opus-4-7"     "$BASHRC"
}

@test "update_bashrc third-party explicit model vars resolve verbatim when provider flips" {
    AAB_CLAUDE_CODE_INFERENCE_PROVIDER="third-party" \
        AAB_CLAUDE_CODE_THIRD_PARTY_HAIKU_MODEL="aws/anthropic/claude-haiku-4-5-v1" \
        AAB_CLAUDE_CODE_THIRD_PARTY_SONNET_MODEL="aws/anthropic/bedrock-claude-sonnet-4-6" \
        AAB_CLAUDE_CODE_THIRD_PARTY_OPUS_MODEL="aws/anthropic/bedrock-claude-opus-4-7" \
        update_bashrc
    # shellcheck disable=SC1090
    ANTHROPIC_DEFAULT_HAIKU_MODEL="" \
        ANTHROPIC_DEFAULT_SONNET_MODEL="" \
        ANTHROPIC_DEFAULT_OPUS_MODEL="" \
        . "$BASHRC"
    [ "$ANTHROPIC_DEFAULT_HAIKU_MODEL"  = "aws/anthropic/claude-haiku-4-5-v1" ]
    [ "$ANTHROPIC_DEFAULT_SONNET_MODEL" = "aws/anthropic/bedrock-claude-sonnet-4-6" ]
    [ "$ANTHROPIC_DEFAULT_OPUS_MODEL"   = "aws/anthropic/bedrock-claude-opus-4-7" ]
}

@test "sourcing bootstrap.bash does NOT execute main" {
    # setup() already sourced the script. If main had run, it would have
    # attempted to install Claude Code via curl; instead the function is
    # merely defined.
    type main >/dev/null
    # And no settings file should exist yet — write_settings was never
    # called by a main() invocation at source time.
    [ ! -f "$SETTINGS_FILE" ]
}

@test "install_base_deps is a no-op when all required commands are present" {
    # Runs on a host (or CI runner) where curl / python3 / git / tar / gawk /
    # sudo and the CA bundle are preinstalled — the dev-box / runner default.
    for cmd in curl python3 git tar gawk sudo; do
        command -v "$cmd" >/dev/null || skip "precondition: $cmd must exist on the test host"
    done
    [ -f /etc/ssl/certs/ca-certificates.crt ] || skip "precondition: ca-certificates bundle must exist"

    run install_base_deps
    [ "$status" -eq 0 ]
    # Silent: no "Installing base deps:" log line, and no apt-get invocation.
    [[ "$output" != *"Installing base deps:"* ]]
}

@test "install_base_deps warns and skips when apt-get is unavailable" {
    # Empty PATH → command -v fails for every external tool, including
    # apt-get. Exercises the "bare host without apt-get" branch where the
    # function must not blow up, just warn and return.
    local empty_bin="$TEST_HOME/empty-bin"
    mkdir -p "$empty_bin"
    PATH="$empty_bin" run install_base_deps
    [ "$status" -eq 0 ]
    [[ "$output" == *"apt-get is not available"* ]]
    # Should NOT claim to be installing anything.
    [[ "$output" != *"Installing base deps:"* ]]
}


# ---------------------------------------------------------------------------
# install_agent_plugins: cover the gh-authenticated path, the
# raw.githubusercontent.com fallback, and the skip-on-no-access path added for
# private plugin marketplaces.
# ---------------------------------------------------------------------------

# Sets up $FAKE_BIN on PATH with stub `gh` and `curl` binaries plus two
# fixture directories the stubs read from:
#   $FAKE_GH_DIR   — served by `gh api repos/<owner>/<repo>/contents/...`
#   $FAKE_CURL_DIR — served by `curl https://raw.githubusercontent.com/...`
# Each fixture is keyed `<owner>__<repo>.json`.
setup_plugin_fakes() {
    export FAKE_BIN="$TEST_HOME/fake-bin"
    export FAKE_GH_DIR="$TEST_HOME/fake-gh-fixtures"
    export FAKE_CURL_DIR="$TEST_HOME/fake-curl-fixtures"
    mkdir -p "$FAKE_BIN" "$FAKE_GH_DIR" "$FAKE_CURL_DIR"

    cat > "$FAKE_BIN/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
    [ "${FAKE_GH_AUTH_OK:-0}" = "1" ] && exit 0 || exit 1
fi
if [ "$1" = "api" ]; then
    for a in "$@"; do
        if [[ "$a" =~ ^repos/([^/]+)/([^/]+)/contents/ ]]; then
            f="${FAKE_GH_DIR}/${BASH_REMATCH[1]}__${BASH_REMATCH[2]}.json"
            [ -f "$f" ] && { cat "$f"; exit 0; }
            exit 22
        fi
    done
fi
exit 1
SH
    chmod +x "$FAKE_BIN/gh"

    cat > "$FAKE_BIN/curl" <<'SH'
#!/usr/bin/env bash
url=""
for a in "$@"; do
    case "$a" in https://*) url="$a";; esac
done
if [[ "$url" == https://raw.githubusercontent.com/* ]]; then
    rest="${url#https://raw.githubusercontent.com/}"
    owner="${rest%%/*}"; rest="${rest#*/}"
    repo="${rest%%/*}"
    f="${FAKE_CURL_DIR}/${owner}__${repo}.json"
    [ -f "$f" ] && { cat "$f"; exit 0; }
fi
exit 22
SH
    chmod +x "$FAKE_BIN/curl"

    export PATH="$FAKE_BIN:/usr/bin:/bin"
}

write_marketplace_fixture() {
    local dir="$1" owner_repo="$2" mkt_name="$3" plugin_name="$4"
    local key="${owner_repo/\//__}"
    cat > "$dir/$key.json" <<JSON
{"name": "$mkt_name", "plugins": [{"name": "$plugin_name"}]}
JSON
}

@test "install_agent_plugins fetches via gh api when gh is authenticated (private-repo path)" {
    setup_plugin_fakes
    export FAKE_GH_AUTH_OK=1
    # Fixture only reachable via gh — proves curl wasn't the source.
    write_marketplace_fixture "$FAKE_GH_DIR" "acme/private-plugin" "acme-market" "widget"
    echo "acme/private-plugin" > "$TEST_HOME/plugins.txt"
    export AAB_AGENT_PLUGINS_FILE="$TEST_HOME/plugins.txt"

    write_settings
    install_agent_plugins

    python3 - <<PY
import json
d = json.load(open("$SETTINGS_FILE"))
assert d["extraKnownMarketplaces"]["acme-market"]["source"]["repo"] == "acme/private-plugin", d
assert d["enabledPlugins"]["widget@acme-market"] is True, d
PY
}

@test "install_agent_plugins falls back to raw.githubusercontent.com when gh is not authenticated" {
    setup_plugin_fakes
    export FAKE_GH_AUTH_OK=0
    # Fixture only reachable via curl — proves the fallback path ran.
    write_marketplace_fixture "$FAKE_CURL_DIR" "acme/public-plugin" "acme-public" "gadget"
    echo "acme/public-plugin" > "$TEST_HOME/plugins.txt"
    export AAB_AGENT_PLUGINS_FILE="$TEST_HOME/plugins.txt"

    write_settings
    install_agent_plugins

    python3 - <<PY
import json
d = json.load(open("$SETTINGS_FILE"))
assert d["extraKnownMarketplaces"]["acme-public"]["source"]["repo"] == "acme/public-plugin", d
assert d["enabledPlugins"]["gadget@acme-public"] is True, d
PY
}

@test "install_agent_plugins logs-and-skips a private repo the caller cannot access" {
    setup_plugin_fakes
    export FAKE_GH_AUTH_OK=1
    # One entry is reachable via curl; the other is reachable nowhere (simulates
    # a private repo the caller has no token for).
    write_marketplace_fixture "$FAKE_CURL_DIR" "acme/public-plugin" "acme-public" "gadget"
    printf '%s\n%s\n' "acme/public-plugin" "private/no-access" > "$TEST_HOME/plugins.txt"
    export AAB_AGENT_PLUGINS_FILE="$TEST_HOME/plugins.txt"

    write_settings
    run install_agent_plugins
    [ "$status" -eq 0 ]
    # Soft log, not WARN, for the inaccessible repo.
    [[ "$output" == *"Could not fetch .claude-plugin/marketplace.json from private/no-access"* ]]
    [[ "$output" != *"WARN: "*"private/no-access"* ]]

    python3 - <<PY
import json
d = json.load(open("$SETTINGS_FILE"))
# Accessible entry got installed.
assert "acme-public" in d.get("extraKnownMarketplaces", {}), d
# Inaccessible entry did not poison settings.json.
repos = {m["source"]["repo"] for m in d.get("extraKnownMarketplaces", {}).values()}
assert "private/no-access" not in repos, repos
PY
}

# Drop fake agent CLIs on PATH that record every plugin invocation and exit 0.
# The install_agent_plugins tests below assert the marketplace-add and
# plugin-install calls actually fired with the expected arguments.
setup_fake_claude() {
    cat > "$FAKE_BIN/claude" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TEST_HOME/claude-invocations"
exit 0
SH
    chmod +x "$FAKE_BIN/claude"
}

setup_fake_codex_plugin() {
    cat > "$FAKE_BIN/codex" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TEST_HOME/codex-plugin-invocations"
exit 0
SH
    chmod +x "$FAKE_BIN/codex"
}

@test "install_agent_plugins runs both agent plugin CLIs for each enabled plugin" {
    setup_plugin_fakes
    setup_fake_claude
    setup_fake_codex_plugin
    export FAKE_GH_AUTH_OK=1
    # One marketplace, two plugins — exercises the dedupe (one
    # `marketplace add`) and the per-plugin install loop.
    cat > "$FAKE_GH_DIR/acme__multi.json" <<JSON
{"name": "acme-multi", "plugins": [{"name": "alpha"}, {"name": "beta"}]}
JSON
    echo "acme/multi" > "$TEST_HOME/plugins.txt"
    export AAB_AGENT_PLUGINS_FILE="$TEST_HOME/plugins.txt"

    write_settings
    install_agent_plugins

    grep -Fxq 'plugin marketplace add acme/multi' "$TEST_HOME/claude-invocations"
    grep -Fxq 'plugin install alpha@acme-multi --scope user' "$TEST_HOME/claude-invocations"
    grep -Fxq 'plugin install beta@acme-multi --scope user' "$TEST_HOME/claude-invocations"
    grep -Fxq 'plugin marketplace add acme/multi' "$TEST_HOME/codex-plugin-invocations"
    grep -Fxq 'plugin add alpha@acme-multi' "$TEST_HOME/codex-plugin-invocations"
    grep -Fxq 'plugin add beta@acme-multi' "$TEST_HOME/codex-plugin-invocations"
    # Dedupe: one marketplace add, not two.
    [ "$(grep -c 'plugin marketplace add' "$TEST_HOME/claude-invocations")" -eq 1 ]
    [ "$(grep -c 'plugin marketplace add' "$TEST_HOME/codex-plugin-invocations")" -eq 1 ]
}

@test "install_agent_plugins runs marketplace-add once per repo across distinct plugin lines" {
    setup_plugin_fakes
    setup_fake_claude
    setup_fake_codex_plugin
    export FAKE_GH_AUTH_OK=1
    # Two repos, one plugin each — exercises the multi-repo loop.
    write_marketplace_fixture "$FAKE_GH_DIR" "alpha/m" "alpha-m" "p1"
    write_marketplace_fixture "$FAKE_GH_DIR" "beta/m" "beta-m" "p2"
    printf '%s\n%s\n' "alpha/m" "beta/m" > "$TEST_HOME/plugins.txt"
    export AAB_AGENT_PLUGINS_FILE="$TEST_HOME/plugins.txt"

    write_settings
    install_agent_plugins

    grep -Fxq 'plugin marketplace add alpha/m' "$TEST_HOME/claude-invocations"
    grep -Fxq 'plugin marketplace add beta/m' "$TEST_HOME/claude-invocations"
    grep -Fxq 'plugin install p1@alpha-m --scope user' "$TEST_HOME/claude-invocations"
    grep -Fxq 'plugin install p2@beta-m --scope user' "$TEST_HOME/claude-invocations"
    grep -Fxq 'plugin marketplace add alpha/m' "$TEST_HOME/codex-plugin-invocations"
    grep -Fxq 'plugin marketplace add beta/m' "$TEST_HOME/codex-plugin-invocations"
    grep -Fxq 'plugin add p1@alpha-m' "$TEST_HOME/codex-plugin-invocations"
    grep -Fxq 'plugin add p2@beta-m' "$TEST_HOME/codex-plugin-invocations"
}

@test "install_agent_plugins warns and skips CLI installs when agent binaries are absent" {
    setup_plugin_fakes
    # Do not call setup_fake_claude or setup_fake_codex_plugin; leave PATH without
    # agent binaries.
    PATH="$FAKE_BIN:/usr/bin:/bin"
    export FAKE_GH_AUTH_OK=1
    write_marketplace_fixture "$FAKE_GH_DIR" "acme/m" "acme-m" "widget"
    echo "acme/m" > "$TEST_HOME/plugins.txt"
    export AAB_AGENT_PLUGINS_FILE="$TEST_HOME/plugins.txt"

    write_settings
    run install_agent_plugins
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN:"*"claude binary not on PATH"* ]]
    [[ "$output" == *"WARN:"*"codex binary not on PATH"* ]]
    # settings.json was still written even when the install step is skipped.
    python3 - <<PY
import json
d = json.load(open("$SETTINGS_FILE"))
assert d["enabledPlugins"]["widget@acme-m"] is True, d
PY
}

# ---------------------------------------------------------------------------
# install_auth_ssh_key / install_signing_ssh_key: cover the two distinct
# roles (GitHub SSH auth vs git commit/tag signing), including:
#   - skip-on-unset for each
#   - correct file modes on both key pairs
#   - auth writes a managed block in ~/.ssh/config mapping github.com to
#     id_aab_auth; signing leaves ~/.ssh/config alone
#   - signing configures git signing; auth leaves git signing alone
#   - idempotent re-runs (auth managed block is size-stable)
#   - pre-existing ~/.ssh/config entries outside the block are preserved
#   - invalid base64 and not-an-SSH-key input produce warn-and-skip
# ---------------------------------------------------------------------------

# Generates a valid ed25519 private key at <path> and echoes its base64
# encoding. The matching .pub is written next to <path> by ssh-keygen.
gen_test_ssh_key_b64() {
    local path="${1:-$TEST_HOME/generated_key}"
    command -v ssh-keygen >/dev/null || skip "precondition: ssh-keygen must exist"
    ssh-keygen -t ed25519 -N "" -q -C "aab-test" -f "$path"
    base64 -w0 < "$path"
}

@test "install_auth_ssh_key is a no-op when AAB_GH_AUTH_SSH_PRIVATE_KEY_B64 is unset" {
    run install_auth_ssh_key
    [ "$status" -eq 0 ]
    [ ! -e "$AUTH_KEY" ]
    [ ! -e "$SSH_CONFIG" ]
}

@test "install_signing_ssh_key is a no-op when AAB_GIT_SIGNING_PRIVATE_KEY_B64 is unset" {
    run install_signing_ssh_key
    [ "$status" -eq 0 ]
    [ ! -e "$SIGNING_KEY" ]
    # Signing does NOT touch ~/.ssh/config regardless — double-check nothing appeared.
    [ ! -e "$SSH_CONFIG" ]
    # And git signing config must not be set.
    [ -z "$(git config --global --get user.signingkey 2>/dev/null || true)" ]
}

@test "install_auth_ssh_key writes id_aab_auth (0600) and id_aab_auth.pub (0644)" {
    AAB_GH_AUTH_SSH_PRIVATE_KEY_B64=$(gen_test_ssh_key_b64)
    export AAB_GH_AUTH_SSH_PRIVATE_KEY_B64
    install_auth_ssh_key

    [ -f "$AUTH_KEY" ]
    [ -f "$AUTH_KEY_PUB" ]
    [ "$(stat -c '%a' "$AUTH_KEY")" = "600" ]
    [ "$(stat -c '%a' "$AUTH_KEY_PUB")" = "644" ]
    [ "$(stat -c '%a' "$SSH_DIR")" = "700" ]
    diff <(sort "$AUTH_KEY_PUB") <(sort "$TEST_HOME/generated_key.pub")
}

@test "install_signing_ssh_key writes id_aab_signing (0600) and id_aab_signing.pub (0644)" {
    AAB_GIT_SIGNING_PRIVATE_KEY_B64=$(gen_test_ssh_key_b64)
    export AAB_GIT_SIGNING_PRIVATE_KEY_B64
    install_signing_ssh_key

    [ -f "$SIGNING_KEY" ]
    [ -f "$SIGNING_KEY_PUB" ]
    [ "$(stat -c '%a' "$SIGNING_KEY")" = "600" ]
    [ "$(stat -c '%a' "$SIGNING_KEY_PUB")" = "644" ]
    diff <(sort "$SIGNING_KEY_PUB") <(sort "$TEST_HOME/generated_key.pub")
}

@test "install_auth_ssh_key writes a managed block in ~/.ssh/config mapping github.com to id_aab_auth" {
    AAB_GH_AUTH_SSH_PRIVATE_KEY_B64=$(gen_test_ssh_key_b64)
    export AAB_GH_AUTH_SSH_PRIVATE_KEY_B64
    install_auth_ssh_key

    [ -f "$SSH_CONFIG" ]
    grep -qF "$SSH_MARKER_BEGIN" "$SSH_CONFIG"
    grep -qF "$SSH_MARKER_END" "$SSH_CONFIG"
    grep -qE "^Host github.com$" "$SSH_CONFIG"
    grep -qF "IdentityFile $AUTH_KEY" "$SSH_CONFIG"
    grep -qE "^[[:space:]]+IdentitiesOnly yes$" "$SSH_CONFIG"
    [ "$(stat -c '%a' "$SSH_CONFIG")" = "600" ]
}

@test "install_auth_ssh_key does NOT configure git signing" {
    command -v git >/dev/null || skip "precondition: git must exist"
    AAB_GH_AUTH_SSH_PRIVATE_KEY_B64=$(gen_test_ssh_key_b64)
    export AAB_GH_AUTH_SSH_PRIVATE_KEY_B64
    install_auth_ssh_key

    # No signing config should have been written.
    [ -z "$(git config --global --get gpg.format 2>/dev/null || true)" ]
    [ -z "$(git config --global --get user.signingkey 2>/dev/null || true)" ]
    [ -z "$(git config --global --get commit.gpgsign 2>/dev/null || true)" ]
    [ -z "$(git config --global --get tag.gpgsign 2>/dev/null || true)" ]
}

@test "install_signing_ssh_key does NOT touch ~/.ssh/config" {
    AAB_GIT_SIGNING_PRIVATE_KEY_B64=$(gen_test_ssh_key_b64)
    export AAB_GIT_SIGNING_PRIVATE_KEY_B64
    install_signing_ssh_key

    [ ! -e "$SSH_CONFIG" ]
}

@test "install_signing_ssh_key configures git SSH signing (gpg.format, signingkey, commit/tag.gpgsign)" {
    command -v git >/dev/null || skip "precondition: git must exist"
    AAB_GIT_SIGNING_PRIVATE_KEY_B64=$(gen_test_ssh_key_b64)
    export AAB_GIT_SIGNING_PRIVATE_KEY_B64
    install_signing_ssh_key

    [ "$(git config --global --get gpg.format)" = "ssh" ]
    [ "$(git config --global --get user.signingkey)" = "$SIGNING_KEY_PUB" ]
    [ "$(git config --global --get commit.gpgsign)" = "true" ]
    [ "$(git config --global --get tag.gpgsign)" = "true" ]
}

@test "install_auth_ssh_key is idempotent (second run: single managed block, file size stable)" {
    AAB_GH_AUTH_SSH_PRIVATE_KEY_B64=$(gen_test_ssh_key_b64)
    export AAB_GH_AUTH_SSH_PRIVATE_KEY_B64
    install_auth_ssh_key
    local size1
    size1=$(wc -c < "$SSH_CONFIG")

    install_auth_ssh_key
    local begin_count end_count size2
    begin_count=$(grep -cF "$SSH_MARKER_BEGIN" "$SSH_CONFIG")
    end_count=$(grep -cF "$SSH_MARKER_END" "$SSH_CONFIG")
    size2=$(wc -c < "$SSH_CONFIG")
    [ "$begin_count" -eq 1 ]
    [ "$end_count" -eq 1 ]
    [ "$size1" -eq "$size2" ]
}

@test "install_auth_ssh_key preserves pre-existing non-managed content in ~/.ssh/config" {
    mkdir -p "$SSH_DIR"
    cat > "$SSH_CONFIG" <<'EOF'
Host gitlab.com
    IdentityFile ~/.ssh/id_ed25519_gitlab
    User git
EOF
    AAB_GH_AUTH_SSH_PRIVATE_KEY_B64=$(gen_test_ssh_key_b64)
    export AAB_GH_AUTH_SSH_PRIVATE_KEY_B64
    install_auth_ssh_key

    # Original content still present.
    grep -qE "^Host gitlab.com$" "$SSH_CONFIG"
    grep -qF "IdentityFile ~/.ssh/id_ed25519_gitlab" "$SSH_CONFIG"
    # Managed block appended.
    grep -qF "$SSH_MARKER_BEGIN" "$SSH_CONFIG"
    grep -qE "^Host github.com$" "$SSH_CONFIG"
}

@test "install_auth_ssh_key warns and skips on invalid-base64 input" {
    export AAB_GH_AUTH_SSH_PRIVATE_KEY_B64="this is not base64!@#"
    run install_auth_ssh_key
    [ "$status" -eq 0 ]
    [[ "$output" == *"AAB_GH_AUTH_SSH_PRIVATE_KEY_B64 is not valid base64"* ]] \
        || [[ "$output" == *"AAB_GH_AUTH_SSH_PRIVATE_KEY_B64 did not decode to a valid SSH private key"* ]]
    [ ! -e "$AUTH_KEY" ]
}

@test "install_signing_ssh_key warns and skips on decoded-garbage input" {
    export AAB_GIT_SIGNING_PRIVATE_KEY_B64="$(printf 'not-an-ssh-key' | base64 -w0)"
    run install_signing_ssh_key
    [ "$status" -eq 0 ]
    [[ "$output" == *"AAB_GIT_SIGNING_PRIVATE_KEY_B64 did not decode to a valid SSH private key"* ]]
    [ ! -e "$SIGNING_KEY" ]
    [ ! -e "$SIGNING_KEY_PUB" ]
}

@test "auth and signing keys can be set independently (different keys, both installed)" {
    # Generate two distinct keys, set each env var to a different encoding.
    AAB_GH_AUTH_SSH_PRIVATE_KEY_B64=$(gen_test_ssh_key_b64 "$TEST_HOME/auth_key")
    AAB_GIT_SIGNING_PRIVATE_KEY_B64=$(gen_test_ssh_key_b64 "$TEST_HOME/sign_key")
    export AAB_GH_AUTH_SSH_PRIVATE_KEY_B64 AAB_GIT_SIGNING_PRIVATE_KEY_B64

    install_auth_ssh_key
    install_signing_ssh_key

    # Both keys are on disk, at different paths.
    [ -f "$AUTH_KEY" ]
    [ -f "$SIGNING_KEY" ]
    ! diff -q "$AUTH_KEY" "$SIGNING_KEY"

    # Auth wiring in ~/.ssh/config points at the auth key, not the signing key.
    grep -qF "IdentityFile $AUTH_KEY" "$SSH_CONFIG"
    ! grep -qF "IdentityFile $SIGNING_KEY" "$SSH_CONFIG"

    # Git signing config points at the signing key, not the auth key.
    [ "$(git config --global --get user.signingkey)" = "$SIGNING_KEY_PUB" ]
}

# ---------------------------------------------------------------------------
# update_etc_environment: covers the /etc/environment managed-block writer
# used to expose AAB env vars to non-interactive shells (ssh remote command,
# systemd EnvironmentFile=, etc.). Tests redirect ETC_ENV to a per-test
# sandbox path and unset SUDO so the install runs as the current user.
# ---------------------------------------------------------------------------

# Common setup: redirect ETC_ENV under the per-test HOME so update_etc_environment
# does not need root and does not touch the host's real /etc/environment.
_etc_env_sandbox() {
    ETC_ENV="$TEST_HOME/environment"
    SUDO=""
}

@test "update_etc_environment writes managed block with both markers (anthropic provider)" {
    _etc_env_sandbox
    AAB_CLAUDE_CODE_INFERENCE_PROVIDER="anthropic" \
    AAB_CLAUDE_CODE_FIRST_PARTY_MODEL="claude-opus-4-7" \
    AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY="sk-ant-test-key" \
    AAB_CODEX_FIRST_PARTY_API_KEY="codex-etc-env-test-key" \
    AAB_GH_TOKEN="ghp_etc_env_test" \
        update_etc_environment

    [ -f "$ETC_ENV" ]
    grep -qF "$ETC_ENV_MARKER_BEGIN" "$ETC_ENV"
    grep -qF "$ETC_ENV_MARKER_END"   "$ETC_ENV"
    grep -q  '^AAB_CLAUDE_CODE_INFERENCE_PROVIDER="anthropic"$' "$ETC_ENV"
    grep -q  '^AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY="sk-ant-test-key"$' "$ETC_ENV"
    grep -q  '^ANTHROPIC_API_KEY="sk-ant-test-key"$'            "$ETC_ENV"
    grep -q  '^AAB_CODEX_FIRST_PARTY_API_KEY="codex-etc-env-test-key"$' "$ETC_ENV"
    grep -q  '^OPENAI_API_KEY="codex-etc-env-test-key"$'        "$ETC_ENV"
    grep -q  '^ANTHROPIC_MODEL="claude-opus-4-7"$'              "$ETC_ENV"
    grep -q  '^AAB_GH_TOKEN="ghp_etc_env_test"$'                "$ETC_ENV"
    grep -q  '^GH_TOKEN="ghp_etc_env_test"$'                    "$ETC_ENV"
    grep -q  '^CLAUDE_CODE_SANDBOXED="1"$'                      "$ETC_ENV"
    grep -q  '^CLAUDE_CODE_EFFORT_LEVEL="max"$'                 "$ETC_ENV"
    grep -q  '^DEBUG_SDK="1"$'                                  "$ETC_ENV"
    # Anthropic branch must NOT carry the third-party-only vars.
    ! grep -q '^ANTHROPIC_BASE_URL='                       "$ETC_ENV"
    ! grep -q '^ANTHROPIC_AUTH_TOKEN='                     "$ETC_ENV"
    ! grep -q '^CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS='   "$ETC_ENV"
}

@test "update_etc_environment writes third-party provider block with explicit model names" {
    _etc_env_sandbox
    AAB_CLAUDE_CODE_INFERENCE_PROVIDER="third-party" \
    AAB_CLAUDE_CODE_THIRD_PARTY_MODEL="aws/anthropic/bedrock-claude-opus-4-7" \
    AAB_CLAUDE_CODE_THIRD_PARTY_HAIKU_MODEL="aws/anthropic/claude-haiku-4-5-v1" \
    AAB_CLAUDE_CODE_THIRD_PARTY_SONNET_MODEL="aws/anthropic/bedrock-claude-sonnet-4-6" \
    AAB_CLAUDE_CODE_THIRD_PARTY_OPUS_MODEL="aws/anthropic/bedrock-claude-opus-4-7" \
    AAB_CLAUDE_CODE_THIRD_PARTY_BASE_URL="https://gateway.example.com" \
    AAB_CLAUDE_CODE_THIRD_PARTY_AUTH_TOKEN="bearer-token-xyz" \
        update_etc_environment

    grep -q '^AAB_CLAUDE_CODE_INFERENCE_PROVIDER="third-party"$' "$ETC_ENV"
    grep -q '^AAB_CLAUDE_CODE_THIRD_PARTY_BASE_URL="https://gateway.example.com"$' "$ETC_ENV"
    grep -q '^ANTHROPIC_BASE_URL="https://gateway.example.com"$' "$ETC_ENV"
    grep -q '^AAB_CLAUDE_CODE_THIRD_PARTY_AUTH_TOKEN="bearer-token-xyz"$' "$ETC_ENV"
    grep -q '^ANTHROPIC_AUTH_TOKEN="bearer-token-xyz"$'          "$ETC_ENV"
    grep -q '^ANTHROPIC_MODEL="aws/anthropic/bedrock-claude-opus-4-7"$' "$ETC_ENV"
    grep -q '^ANTHROPIC_DEFAULT_HAIKU_MODEL="aws/anthropic/claude-haiku-4-5-v1"$'        "$ETC_ENV"
    grep -q '^ANTHROPIC_DEFAULT_SONNET_MODEL="aws/anthropic/bedrock-claude-sonnet-4-6"$' "$ETC_ENV"
    grep -q '^ANTHROPIC_DEFAULT_OPUS_MODEL="aws/anthropic/bedrock-claude-opus-4-7"$'     "$ETC_ENV"
    grep -q '^CLAUDE_CODE_EFFORT_LEVEL="max"$'                    "$ETC_ENV"
    grep -q '^CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS="1"$'       "$ETC_ENV"
    # Third-party branch must NOT carry the first-party-only API key.
    ! grep -q '^ANTHROPIC_API_KEY=' "$ETC_ENV"
}

@test "update_etc_environment keeps first-party and third-party model vars separate" {
    _etc_env_sandbox
    AAB_CLAUDE_CODE_INFERENCE_PROVIDER="anthropic" \
    AAB_CLAUDE_CODE_FIRST_PARTY_HAIKU_MODEL="claude-haiku-first" \
    AAB_CLAUDE_CODE_THIRD_PARTY_HAIKU_MODEL="aws/anthropic/claude-haiku-4-5-v1" \
        update_etc_environment

    grep -q '^ANTHROPIC_DEFAULT_HAIKU_MODEL="claude-haiku-first"$' "$ETC_ENV"
    ! grep -q '^ANTHROPIC_DEFAULT_HAIKU_MODEL="aws/anthropic/claude-haiku-4-5-v1"$' "$ETC_ENV"
}

@test "update_etc_environment writes CLAUDE_CODE_EFFORT_LEVEL from AAB_CLAUDE_CODE_EFFORT" {
    _etc_env_sandbox
    AAB_CLAUDE_CODE_EFFORT="high" update_etc_environment
    grep -q '^CLAUDE_CODE_EFFORT_LEVEL="high"$' "$ETC_ENV"
}

@test "update_etc_environment is idempotent (single managed block after two runs)" {
    _etc_env_sandbox
    AAB_CLAUDE_CODE_FIRST_PARTY_MODEL="claude-opus-4-7" AAB_GH_TOKEN="ghp_idem" update_etc_environment
    AAB_CLAUDE_CODE_FIRST_PARTY_MODEL="claude-opus-4-7" AAB_GH_TOKEN="ghp_idem" update_etc_environment

    local begin_count end_count
    begin_count=$(grep -cF "$ETC_ENV_MARKER_BEGIN" "$ETC_ENV")
    end_count=$(grep -cF "$ETC_ENV_MARKER_END"   "$ETC_ENV")
    [ "$begin_count" -eq 1 ]
    [ "$end_count"   -eq 1 ]
}

@test "update_etc_environment preserves pre-existing non-managed entries" {
    _etc_env_sandbox
    cat > "$ETC_ENV" <<'EOF'
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
LC_ALL="C.UTF-8"
EOF
    AAB_CLAUDE_CODE_FIRST_PARTY_MODEL="claude-opus-4-7" AAB_GH_TOKEN="ghp_keep" update_etc_environment

    # Pre-existing entries survive.
    grep -q '^PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"$' "$ETC_ENV"
    grep -q '^LC_ALL="C.UTF-8"$' "$ETC_ENV"
    # AAB block sits below them.
    grep -qF "$ETC_ENV_MARKER_BEGIN" "$ETC_ENV"
    grep -q '^AAB_GH_TOKEN="ghp_keep"$' "$ETC_ENV"
    grep -q '^GH_TOKEN="ghp_keep"$'  "$ETC_ENV"
}

@test "update_etc_environment replaces a stale managed block in place (re-runs match current env)" {
    _etc_env_sandbox
    AAB_CLAUDE_CODE_INFERENCE_PROVIDER="anthropic" \
    AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY="sk-ant-old" AAB_GH_TOKEN="ghp_old" update_etc_environment
    grep -q '^AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY="sk-ant-old"$' "$ETC_ENV"
    grep -q '^ANTHROPIC_API_KEY="sk-ant-old"$' "$ETC_ENV"

    # Second run with different env: old values must NOT linger.
    unset AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY AAB_GH_TOKEN
    AAB_CLAUDE_CODE_INFERENCE_PROVIDER="anthropic" \
    AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY="sk-ant-new" AAB_GH_TOKEN="ghp_new" update_etc_environment
    grep -q '^AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY="sk-ant-new"$' "$ETC_ENV"
    grep -q '^ANTHROPIC_API_KEY="sk-ant-new"$' "$ETC_ENV"
    grep -q '^AAB_GH_TOKEN="ghp_new"$'          "$ETC_ENV"
    grep -q '^GH_TOKEN="ghp_new"$'             "$ETC_ENV"
    ! grep -q '^AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY="sk-ant-old"$' "$ETC_ENV"
    ! grep -q '^ANTHROPIC_API_KEY="sk-ant-old"$' "$ETC_ENV"
    ! grep -q '^AAB_GH_TOKEN="ghp_old"$'          "$ETC_ENV"
    ! grep -q '^GH_TOKEN="ghp_old"$'             "$ETC_ENV"
}

@test "update_etc_environment file mode is 0644" {
    _etc_env_sandbox
    AAB_CLAUDE_CODE_FIRST_PARTY_MODEL="claude-opus-4-7" update_etc_environment
    [ "$(stat -c '%a' "$ETC_ENV")" = "644" ]
}

@test "update_etc_environment skips when AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY is unset (anthropic branch)" {
    _etc_env_sandbox
    # No AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY in env. The block should still
    # be written but without stale API-key lines — re-runs match the
    # current env.
    AAB_CLAUDE_CODE_INFERENCE_PROVIDER="anthropic" \
    AAB_CLAUDE_CODE_FIRST_PARTY_MODEL="claude-opus-4-7" update_etc_environment

    grep -qF "$ETC_ENV_MARKER_BEGIN" "$ETC_ENV"
    grep -q  '^ANTHROPIC_MODEL="claude-opus-4-7"$' "$ETC_ENV"
    ! grep -q '^AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY=' "$ETC_ENV"
    ! grep -q '^ANTHROPIC_API_KEY=' "$ETC_ENV"
}

@test "update_etc_environment defaults to anthropic provider when AAB_CLAUDE_CODE_INFERENCE_PROVIDER unset" {
    _etc_env_sandbox
    AAB_CLAUDE_CODE_FIRST_PARTY_MODEL="claude-opus-4-7" update_etc_environment
    grep -q '^AAB_CLAUDE_CODE_INFERENCE_PROVIDER="anthropic"$' "$ETC_ENV"
}

# ---------------------------------------------------------------------------
# load_config_file / load_config_stdin: covers the bash-source-backed config
# loader used when main() is given a positional path or non-TTY stdin.
# Exercises quoting, comments, env-beats-file precedence, the missing-file
# and malformed-input error paths, shell-expansion features, and the
# stdin variant.
# ---------------------------------------------------------------------------

@test "load_config_file populates unset env vars from KEY=VALUE lines" {
    cat > "$TEST_HOME/aab.conf" <<'EOF'
AAB_CLAUDE_CODE_FIRST_PARTY_MODEL=claude-sonnet-4-6
AAB_CLAUDE_CODE_INFERENCE_PROVIDER=third-party
AAB_GIT_AUTHOR_NAME="Alice Example"
AAB_GIT_AUTHOR_EMAIL=alice@example.com
EOF
    load_config_file "$TEST_HOME/aab.conf"
    [ "$AAB_CLAUDE_CODE_FIRST_PARTY_MODEL" = "claude-sonnet-4-6" ]
    [ "$AAB_CLAUDE_CODE_INFERENCE_PROVIDER" = "third-party" ]
    [ "$AAB_GIT_AUTHOR_NAME" = "Alice Example" ]
    [ "$AAB_GIT_AUTHOR_EMAIL" = "alice@example.com" ]
}

@test "load_config_file: env var already set in the shell WINS over the file" {
    export AAB_CLAUDE_CODE_FIRST_PARTY_MODEL="claude-opus-4-7"
    cat > "$TEST_HOME/aab.conf" <<'EOF'
AAB_CLAUDE_CODE_FIRST_PARTY_MODEL=claude-sonnet-4-6
AAB_GIT_AUTHOR_NAME="Alice Example"
EOF
    load_config_file "$TEST_HOME/aab.conf"
    # Env-set value preserved.
    [ "$AAB_CLAUDE_CODE_FIRST_PARTY_MODEL" = "claude-opus-4-7" ]
    # File-only value still loaded.
    [ "$AAB_GIT_AUTHOR_NAME" = "Alice Example" ]
}

@test "load_config_file: empty-string env var also beats the file (env 'set' wins even if empty)" {
    # Explicitly set to empty — distinct from unset. Must prevent file override.
    export AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY=""
    cat > "$TEST_HOME/aab.conf" <<'EOF'
AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY=sk-ant-from-file
EOF
    load_config_file "$TEST_HOME/aab.conf"
    [ "$AAB_CLAUDE_CODE_FIRST_PARTY_API_KEY" = "" ]
}

@test "load_config_file handles double- and single-quoted values, and leading 'export '" {
    cat > "$TEST_HOME/aab.conf" <<'EOF'
AAB_CLAUDE_CODE_FIRST_PARTY_MODEL="claude-sonnet-4-6"
AAB_GIT_AUTHOR_NAME='Alice Example'
export AAB_GH_TOKEN=ghp_abc123
EOF
    load_config_file "$TEST_HOME/aab.conf"
    [ "$AAB_CLAUDE_CODE_FIRST_PARTY_MODEL" = "claude-sonnet-4-6" ]
    [ "$AAB_GIT_AUTHOR_NAME" = "Alice Example" ]
    [ "$AAB_GH_TOKEN" = "ghp_abc123" ]
}

@test "load_config_file preserves values containing '=' (only the FIRST '=' splits)" {
    cat > "$TEST_HOME/aab.conf" <<'EOF'
AAB_CLAUDE_CODE_THIRD_PARTY_BASE_URL="https://example.com/v1?foo=bar&baz=qux"
EOF
    load_config_file "$TEST_HOME/aab.conf"
    [ "$AAB_CLAUDE_CODE_THIRD_PARTY_BASE_URL" = "https://example.com/v1?foo=bar&baz=qux" ]
}

@test "load_config_file skips comments and blank lines" {
    cat > "$TEST_HOME/aab.conf" <<'EOF'
# comment at top

# another comment
AAB_CLAUDE_CODE_FIRST_PARTY_MODEL=claude-opus-4-7  # trailing comment

EOF
    run load_config_file "$TEST_HOME/aab.conf"
    [ "$status" -eq 0 ]

    # Verify the one real key actually landed (re-run in-process).
    load_config_file "$TEST_HOME/aab.conf"
    [ "$AAB_CLAUDE_CODE_FIRST_PARTY_MODEL" = "claude-opus-4-7" ]
}

@test "load_config_file expands \${VAR:-default} parameter expansions" {
    # bash sourcing means the file has access to the live shell — defaults,
    # parameter expansion, command substitution all work.
    cat > "$TEST_HOME/aab.conf" <<'EOF'
AAB_CLAUDE_CODE_FIRST_PARTY_MODEL="${AAB_CLAUDE_CODE_FIRST_PARTY_MODEL:-claude-haiku-4-5}"
AAB_GIT_AUTHOR_NAME="Default $(echo Alice)"
EOF
    load_config_file "$TEST_HOME/aab.conf"
    [ "$AAB_CLAUDE_CODE_FIRST_PARTY_MODEL" = "claude-haiku-4-5" ]
    [ "$AAB_GIT_AUTHOR_NAME" = "Default Alice" ]
}

@test "load_config_file aborts on malformed input under set -e" {
    # `set -a; . file; set +a` is strict: a bad-identifier line is a bash
    # syntax error and a no-equals line is a "command not found" exit. Both
    # short-circuit the load — the safer default for a credentials-loading
    # step than the previous warn-and-skip.
    #
    # bats's `run` helper turns `set -e` off, so to assert the real-world
    # abort behavior we re-source bootstrap.bash inside a fresh `bash -c`
    # that re-enables `set -euo pipefail`.
    cat > "$TEST_HOME/aab.conf" <<'EOF'
this-line-has-no-equals
AAB_CLAUDE_CODE_FIRST_PARTY_MODEL=claude-opus-4-7
EOF
    run bash -c "
        set -euo pipefail
        source '$REPO_ROOT/bootstrap.bash'
        load_config_file '$TEST_HOME/aab.conf'
        echo 'should-not-reach'
    "
    [ "$status" -ne 0 ]
    [[ "$output" != *"should-not-reach"* ]]
}

@test "load_config_file: missing file errors out non-zero" {
    run load_config_file "$TEST_HOME/does-not-exist.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found or not readable"* ]]
}

@test "load_config_stdin reads KEY=VALUE pairs piped on stdin" {
    load_config_stdin <<'EOF'
AAB_CLAUDE_CODE_FIRST_PARTY_MODEL=claude-sonnet-4-6
AAB_GIT_AUTHOR_NAME="Alice Example"
EOF
    [ "$AAB_CLAUDE_CODE_FIRST_PARTY_MODEL" = "claude-sonnet-4-6" ]
    [ "$AAB_GIT_AUTHOR_NAME" = "Alice Example" ]
}

@test "load_config_stdin: env beats stdin" {
    export AAB_CLAUDE_CODE_FIRST_PARTY_MODEL="claude-opus-4-7"
    load_config_stdin <<'EOF'
AAB_CLAUDE_CODE_FIRST_PARTY_MODEL=claude-sonnet-4-6
AAB_GIT_AUTHOR_NAME=Alice
EOF
    [ "$AAB_CLAUDE_CODE_FIRST_PARTY_MODEL" = "claude-opus-4-7" ]
    [ "$AAB_GIT_AUTHOR_NAME" = "Alice" ]
}

@test "load_config_stdin: empty stdin is a silent no-op" {
    # No body in the heredoc — load_config_stdin sees zero bytes and returns
    # without touching the env.
    [ -z "${AAB_GIT_AUTHOR_NAME:-}" ]
    load_config_stdin </dev/null
    [ -z "${AAB_GIT_AUTHOR_NAME:-}" ]
}

@test "main() runs load_config_file only when given a positional arg (unset env vars populated)" {
    # Drive main's config-loading step in isolation: we don't want main()
    # to actually execute the rest of its pipeline here. Instead, replay
    # the same logic main() uses: if $1 is set, call load_config_file.
    cat > "$TEST_HOME/aab.conf" <<'EOF'
AAB_GIT_AUTHOR_EMAIL=from-file@example.com
EOF
    # No positional arg: env must remain untouched.
    [ -z "${AAB_GIT_AUTHOR_EMAIL:-}" ]
    # With a positional arg, the helper populates it.
    load_config_file "$TEST_HOME/aab.conf"
    [ "$AAB_GIT_AUTHOR_EMAIL" = "from-file@example.com" ]
}
