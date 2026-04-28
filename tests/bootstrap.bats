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
          AAB_CLAUDE_CODE_PLUGINS_FILE AAB_CLAUDE_CODE_PLUGINS_URL
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
    # Silent: no "installing base deps:" log line, and no apt-get invocation.
    [[ "$output" != *"installing base deps:"* ]]
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
    [[ "$output" != *"installing base deps:"* ]]
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
    [[ "$output" == *"could not fetch .claude-plugin/marketplace.json from private/no-access"* ]]
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
