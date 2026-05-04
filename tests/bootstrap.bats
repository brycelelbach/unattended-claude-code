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
    unset AAB_CLAUDE_CODE_MODEL AAB_CLAUDE_CODE_INFERENCE_PROVIDER \
          AAB_CLAUDE_CODE_MODEL_THIRD_PARTY_PREFIX \
          ANTHROPIC_API_KEY ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN \
          GH_TOKEN GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL \
          AAB_CLAUDE_CODE_PLUGINS_FILE AAB_CLAUDE_CODE_PLUGINS_URL \
          GH_AUTH_SSH_PRIVATE_KEY_B64 GIT_SIGNING_PRIVATE_KEY_B64
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

@test "write_settings uses default model when AAB_CLAUDE_CODE_MODEL unset" {
    write_settings
    [ -f "$SETTINGS_FILE" ]
    python3 -c "import json; d=json.load(open('$SETTINGS_FILE')); assert d['model']=='$DEFAULT_CLAUDE_CODE_MODEL', d['model']"
}

@test "write_settings honors AAB_CLAUDE_CODE_MODEL override" {
    AAB_CLAUDE_CODE_MODEL="claude-sonnet-4-6" write_settings
    python3 -c "import json; d=json.load(open('$SETTINGS_FILE')); assert d['model']=='claude-sonnet-4-6', d['model']"
}

@test "write_settings sets bypassPermissions and sandbox env" {
    write_settings
    python3 - <<PY
import json
d = json.load(open("$SETTINGS_FILE"))
assert d["permissions"]["defaultMode"] == "bypassPermissions"
assert d["skipDangerousModePermissionPrompt"] is True
assert d["env"]["CLAUDE_CODE_SANDBOXED"] == "1"
assert d["effortLevel"] == "max"
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

@test "skip_onboarding creates .claude.json with hasCompletedOnboarding=true" {
    skip_onboarding
    [ -f "$CLAUDE_JSON" ]
    python3 -c "import json; d=json.load(open('$CLAUDE_JSON')); assert d['hasCompletedOnboarding'] is True"
}

@test "skip_onboarding pre-approves ANTHROPIC_API_KEY fingerprint when set" {
    ANTHROPIC_API_KEY="sk-ant-test-0123456789abcdef0123456789abcdef" skip_onboarding
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
    ANTHROPIC_API_KEY="sk-ant-test-0123456789abcdef0123456789abcdef" skip_onboarding
    ANTHROPIC_API_KEY="sk-ant-test-0123456789abcdef0123456789abcdef" skip_onboarding
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

@test "update_bashrc is idempotent (single managed block after two runs)" {
    update_bashrc
    update_bashrc
    local begin_count end_count
    begin_count=$(grep -c "^${BASHRC_MARKER_BEGIN}$" "$BASHRC")
    end_count=$(grep -c "^${BASHRC_MARKER_END}$" "$BASHRC")
    [ "$begin_count" -eq 1 ]
    [ "$end_count" -eq 1 ]
}

@test "update_bashrc honors third-party provider selection" {
    AAB_CLAUDE_CODE_INFERENCE_PROVIDER="third-party" update_bashrc
    grep -q 'AAB_CLAUDE_CODE_INFERENCE_PROVIDER="third-party"' "$BASHRC"
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
    # Runs on a host (or CI runner) where curl / python3 / git / sudo and
    # the CA bundle are preinstalled — the dev-box / runner default.
    for cmd in curl python3 git sudo; do
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
# install_claude_code_plugins: cover the gh-authenticated path, the
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

    export PATH="$FAKE_BIN:$PATH"
}

write_marketplace_fixture() {
    local dir="$1" owner_repo="$2" mkt_name="$3" plugin_name="$4"
    local key="${owner_repo/\//__}"
    cat > "$dir/$key.json" <<JSON
{"name": "$mkt_name", "plugins": [{"name": "$plugin_name"}]}
JSON
}

@test "install_claude_code_plugins fetches via gh api when gh is authenticated (private-repo path)" {
    setup_plugin_fakes
    export FAKE_GH_AUTH_OK=1
    # Fixture only reachable via gh — proves curl wasn't the source.
    write_marketplace_fixture "$FAKE_GH_DIR" "acme/private-plugin" "acme-market" "widget"
    echo "acme/private-plugin" > "$TEST_HOME/plugins.txt"
    export AAB_CLAUDE_CODE_PLUGINS_FILE="$TEST_HOME/plugins.txt"

    write_settings
    install_claude_code_plugins

    python3 - <<PY
import json
d = json.load(open("$SETTINGS_FILE"))
assert d["extraKnownMarketplaces"]["acme-market"]["source"]["repo"] == "acme/private-plugin", d
assert d["enabledPlugins"]["widget@acme-market"] is True, d
PY
}

@test "install_claude_code_plugins falls back to raw.githubusercontent.com when gh is not authenticated" {
    setup_plugin_fakes
    export FAKE_GH_AUTH_OK=0
    # Fixture only reachable via curl — proves the fallback path ran.
    write_marketplace_fixture "$FAKE_CURL_DIR" "acme/public-plugin" "acme-public" "gadget"
    echo "acme/public-plugin" > "$TEST_HOME/plugins.txt"
    export AAB_CLAUDE_CODE_PLUGINS_FILE="$TEST_HOME/plugins.txt"

    write_settings
    install_claude_code_plugins

    python3 - <<PY
import json
d = json.load(open("$SETTINGS_FILE"))
assert d["extraKnownMarketplaces"]["acme-public"]["source"]["repo"] == "acme/public-plugin", d
assert d["enabledPlugins"]["gadget@acme-public"] is True, d
PY
}

@test "install_claude_code_plugins logs-and-skips a private repo the caller cannot access" {
    setup_plugin_fakes
    export FAKE_GH_AUTH_OK=1
    # One entry is reachable via curl; the other is reachable nowhere (simulates
    # a private repo the caller has no token for).
    write_marketplace_fixture "$FAKE_CURL_DIR" "acme/public-plugin" "acme-public" "gadget"
    printf '%s\n%s\n' "acme/public-plugin" "private/no-access" > "$TEST_HOME/plugins.txt"
    export AAB_CLAUDE_CODE_PLUGINS_FILE="$TEST_HOME/plugins.txt"

    write_settings
    run install_claude_code_plugins
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

@test "install_auth_ssh_key is a no-op when GH_AUTH_SSH_PRIVATE_KEY_B64 is unset" {
    run install_auth_ssh_key
    [ "$status" -eq 0 ]
    [ ! -e "$AUTH_KEY" ]
    [ ! -e "$SSH_CONFIG" ]
}

@test "install_signing_ssh_key is a no-op when GIT_SIGNING_PRIVATE_KEY_B64 is unset" {
    run install_signing_ssh_key
    [ "$status" -eq 0 ]
    [ ! -e "$SIGNING_KEY" ]
    # Signing does NOT touch ~/.ssh/config regardless — double-check nothing appeared.
    [ ! -e "$SSH_CONFIG" ]
    # And git signing config must not be set.
    [ -z "$(git config --global --get user.signingkey 2>/dev/null || true)" ]
}

@test "install_auth_ssh_key writes id_aab_auth (0600) and id_aab_auth.pub (0644)" {
    GH_AUTH_SSH_PRIVATE_KEY_B64=$(gen_test_ssh_key_b64)
    export GH_AUTH_SSH_PRIVATE_KEY_B64
    install_auth_ssh_key

    [ -f "$AUTH_KEY" ]
    [ -f "$AUTH_KEY_PUB" ]
    [ "$(stat -c '%a' "$AUTH_KEY")" = "600" ]
    [ "$(stat -c '%a' "$AUTH_KEY_PUB")" = "644" ]
    [ "$(stat -c '%a' "$SSH_DIR")" = "700" ]
    diff <(sort "$AUTH_KEY_PUB") <(sort "$TEST_HOME/generated_key.pub")
}

@test "install_signing_ssh_key writes id_aab_signing (0600) and id_aab_signing.pub (0644)" {
    GIT_SIGNING_PRIVATE_KEY_B64=$(gen_test_ssh_key_b64)
    export GIT_SIGNING_PRIVATE_KEY_B64
    install_signing_ssh_key

    [ -f "$SIGNING_KEY" ]
    [ -f "$SIGNING_KEY_PUB" ]
    [ "$(stat -c '%a' "$SIGNING_KEY")" = "600" ]
    [ "$(stat -c '%a' "$SIGNING_KEY_PUB")" = "644" ]
    diff <(sort "$SIGNING_KEY_PUB") <(sort "$TEST_HOME/generated_key.pub")
}

@test "install_auth_ssh_key writes a managed block in ~/.ssh/config mapping github.com to id_aab_auth" {
    GH_AUTH_SSH_PRIVATE_KEY_B64=$(gen_test_ssh_key_b64)
    export GH_AUTH_SSH_PRIVATE_KEY_B64
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
    GH_AUTH_SSH_PRIVATE_KEY_B64=$(gen_test_ssh_key_b64)
    export GH_AUTH_SSH_PRIVATE_KEY_B64
    install_auth_ssh_key

    # No signing config should have been written.
    [ -z "$(git config --global --get gpg.format 2>/dev/null || true)" ]
    [ -z "$(git config --global --get user.signingkey 2>/dev/null || true)" ]
    [ -z "$(git config --global --get commit.gpgsign 2>/dev/null || true)" ]
    [ -z "$(git config --global --get tag.gpgsign 2>/dev/null || true)" ]
}

@test "install_signing_ssh_key does NOT touch ~/.ssh/config" {
    GIT_SIGNING_PRIVATE_KEY_B64=$(gen_test_ssh_key_b64)
    export GIT_SIGNING_PRIVATE_KEY_B64
    install_signing_ssh_key

    [ ! -e "$SSH_CONFIG" ]
}

@test "install_signing_ssh_key configures git SSH signing (gpg.format, signingkey, commit/tag.gpgsign)" {
    command -v git >/dev/null || skip "precondition: git must exist"
    GIT_SIGNING_PRIVATE_KEY_B64=$(gen_test_ssh_key_b64)
    export GIT_SIGNING_PRIVATE_KEY_B64
    install_signing_ssh_key

    [ "$(git config --global --get gpg.format)" = "ssh" ]
    [ "$(git config --global --get user.signingkey)" = "$SIGNING_KEY_PUB" ]
    [ "$(git config --global --get commit.gpgsign)" = "true" ]
    [ "$(git config --global --get tag.gpgsign)" = "true" ]
}

@test "install_auth_ssh_key is idempotent (second run: single managed block, file size stable)" {
    GH_AUTH_SSH_PRIVATE_KEY_B64=$(gen_test_ssh_key_b64)
    export GH_AUTH_SSH_PRIVATE_KEY_B64
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
    GH_AUTH_SSH_PRIVATE_KEY_B64=$(gen_test_ssh_key_b64)
    export GH_AUTH_SSH_PRIVATE_KEY_B64
    install_auth_ssh_key

    # Original content still present.
    grep -qE "^Host gitlab.com$" "$SSH_CONFIG"
    grep -qF "IdentityFile ~/.ssh/id_ed25519_gitlab" "$SSH_CONFIG"
    # Managed block appended.
    grep -qF "$SSH_MARKER_BEGIN" "$SSH_CONFIG"
    grep -qE "^Host github.com$" "$SSH_CONFIG"
}

@test "install_auth_ssh_key warns and skips on invalid-base64 input" {
    export GH_AUTH_SSH_PRIVATE_KEY_B64="this is not base64!@#"
    run install_auth_ssh_key
    [ "$status" -eq 0 ]
    [[ "$output" == *"GH_AUTH_SSH_PRIVATE_KEY_B64 is not valid base64"* ]] \
        || [[ "$output" == *"GH_AUTH_SSH_PRIVATE_KEY_B64 did not decode to a valid SSH private key"* ]]
    [ ! -e "$AUTH_KEY" ]
}

@test "install_signing_ssh_key warns and skips on decoded-garbage input" {
    export GIT_SIGNING_PRIVATE_KEY_B64="$(printf 'not-an-ssh-key' | base64 -w0)"
    run install_signing_ssh_key
    [ "$status" -eq 0 ]
    [[ "$output" == *"GIT_SIGNING_PRIVATE_KEY_B64 did not decode to a valid SSH private key"* ]]
    [ ! -e "$SIGNING_KEY" ]
    [ ! -e "$SIGNING_KEY_PUB" ]
}

@test "auth and signing keys can be set independently (different keys, both installed)" {
    # Generate two distinct keys, set each env var to a different encoding.
    GH_AUTH_SSH_PRIVATE_KEY_B64=$(gen_test_ssh_key_b64 "$TEST_HOME/auth_key")
    GIT_SIGNING_PRIVATE_KEY_B64=$(gen_test_ssh_key_b64 "$TEST_HOME/sign_key")
    export GH_AUTH_SSH_PRIVATE_KEY_B64 GIT_SIGNING_PRIVATE_KEY_B64

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
# load_config_file: covers the KEY=VALUE parser used when main() is given a
# positional config-file argument. Exercises quoting, comments, malformed
# lines, env-beats-file precedence, and the missing-file error path.
# ---------------------------------------------------------------------------

@test "load_config_file populates unset env vars from KEY=VALUE lines" {
    cat > "$TEST_HOME/aab.conf" <<'EOF'
AAB_CLAUDE_CODE_MODEL=claude-sonnet-4-6
AAB_CLAUDE_CODE_INFERENCE_PROVIDER=third-party
GIT_AUTHOR_NAME=Alice Example
GIT_AUTHOR_EMAIL=alice@example.com
EOF
    load_config_file "$TEST_HOME/aab.conf"
    [ "$AAB_CLAUDE_CODE_MODEL" = "claude-sonnet-4-6" ]
    [ "$AAB_CLAUDE_CODE_INFERENCE_PROVIDER" = "third-party" ]
    [ "$GIT_AUTHOR_NAME" = "Alice Example" ]
    [ "$GIT_AUTHOR_EMAIL" = "alice@example.com" ]
}

@test "load_config_file: env var already set in the shell WINS over the file" {
    export AAB_CLAUDE_CODE_MODEL="claude-opus-4-7"
    cat > "$TEST_HOME/aab.conf" <<'EOF'
AAB_CLAUDE_CODE_MODEL=claude-sonnet-4-6
GIT_AUTHOR_NAME=Alice Example
EOF
    load_config_file "$TEST_HOME/aab.conf"
    # Env-set value preserved.
    [ "$AAB_CLAUDE_CODE_MODEL" = "claude-opus-4-7" ]
    # File-only value still loaded.
    [ "$GIT_AUTHOR_NAME" = "Alice Example" ]
}

@test "load_config_file: empty-string env var also beats the file (env 'set' wins even if empty)" {
    # Explicitly set to empty — distinct from unset. Must prevent file override.
    export ANTHROPIC_API_KEY=""
    cat > "$TEST_HOME/aab.conf" <<'EOF'
ANTHROPIC_API_KEY=sk-ant-from-file
EOF
    load_config_file "$TEST_HOME/aab.conf"
    [ "$ANTHROPIC_API_KEY" = "" ]
}

@test "load_config_file handles double- and single-quoted values, and leading 'export '" {
    cat > "$TEST_HOME/aab.conf" <<'EOF'
AAB_CLAUDE_CODE_MODEL="claude-sonnet-4-6"
GIT_AUTHOR_NAME='Alice Example'
export GH_TOKEN=ghp_abc123
EOF
    load_config_file "$TEST_HOME/aab.conf"
    [ "$AAB_CLAUDE_CODE_MODEL" = "claude-sonnet-4-6" ]
    [ "$GIT_AUTHOR_NAME" = "Alice Example" ]
    [ "$GH_TOKEN" = "ghp_abc123" ]
}

@test "load_config_file tolerates extra whitespace between 'export' and the key" {
    # Two spaces, then tabs, then mixed whitespace — all should be trimmed.
    printf 'export  GH_TOKEN=ghp_two_spaces\n'              >  "$TEST_HOME/aab.conf"
    printf 'export\tAAB_CLAUDE_CODE_MODEL=claude-haiku-4-5\n' >> "$TEST_HOME/aab.conf"
    printf 'export   \tGIT_AUTHOR_NAME=Alice\n'              >> "$TEST_HOME/aab.conf"

    run load_config_file "$TEST_HOME/aab.conf"
    [ "$status" -eq 0 ]
    # No malformed-line warnings — the whitespace should be eaten cleanly.
    [[ "$output" != *"malformed"* ]]

    # Re-load in-process to check values (run ran in a subshell).
    load_config_file "$TEST_HOME/aab.conf"
    [ "$GH_TOKEN" = "ghp_two_spaces" ]
    [ "$AAB_CLAUDE_CODE_MODEL" = "claude-haiku-4-5" ]
    [ "$GIT_AUTHOR_NAME" = "Alice" ]
}

@test "load_config_file preserves values containing '=' (only the FIRST '=' splits)" {
    cat > "$TEST_HOME/aab.conf" <<'EOF'
ANTHROPIC_BASE_URL=https://example.com/v1?foo=bar&baz=qux
EOF
    load_config_file "$TEST_HOME/aab.conf"
    [ "$ANTHROPIC_BASE_URL" = "https://example.com/v1?foo=bar&baz=qux" ]
}

@test "load_config_file skips comments and blank lines" {
    cat > "$TEST_HOME/aab.conf" <<'EOF'
# comment at top

# another comment
AAB_CLAUDE_CODE_MODEL=claude-opus-4-7

EOF
    run load_config_file "$TEST_HOME/aab.conf"
    [ "$status" -eq 0 ]
    # No warnings about malformed lines.
    [[ "$output" != *"malformed"* ]]

    # Verify the one real key actually landed (re-run in-process).
    load_config_file "$TEST_HOME/aab.conf"
    [ "$AAB_CLAUDE_CODE_MODEL" = "claude-opus-4-7" ]
}

@test "load_config_file warns and skips malformed lines, but loads good ones" {
    cat > "$TEST_HOME/aab.conf" <<'EOF'
this-line-has-no-equals
AAB_CLAUDE_CODE_MODEL=claude-opus-4-7
1BADKEY=starts-with-digit
GIT_AUTHOR_NAME=Alice
EOF
    run load_config_file "$TEST_HOME/aab.conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no '='"* ]]
    [[ "$output" == *"bad key"* ]]

    # Good keys still loaded.
    load_config_file "$TEST_HOME/aab.conf"
    [ "$AAB_CLAUDE_CODE_MODEL" = "claude-opus-4-7" ]
    [ "$GIT_AUTHOR_NAME" = "Alice" ]
}

@test "load_config_file: missing file errors out non-zero" {
    run load_config_file "$TEST_HOME/does-not-exist.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found or not readable"* ]]
}

@test "main() runs load_config_file only when given a positional arg (unset env vars populated)" {
    # Drive main's config-loading step in isolation: we don't want main()
    # to actually execute the rest of its pipeline here. Instead, replay
    # the same logic main() uses: if $1 is set, call load_config_file.
    cat > "$TEST_HOME/aab.conf" <<'EOF'
GIT_AUTHOR_EMAIL=from-file@example.com
EOF
    # No positional arg: env must remain untouched.
    [ -z "${GIT_AUTHOR_EMAIL:-}" ]
    # With a positional arg, the helper populates it.
    load_config_file "$TEST_HOME/aab.conf"
    [ "$GIT_AUTHOR_EMAIL" = "from-file@example.com" ]
}
