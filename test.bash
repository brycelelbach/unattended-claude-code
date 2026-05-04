#!/usr/bin/env bash
# Run the project's tests. Mirrors the jobs in .github/workflows/ci.yml so
# "works locally" == "will pass CI".
#
# Usage:
#   ./test.bash              lint + unit (default; fast, no side effects)
#   ./test.bash --lint       bash -n + shellcheck
#   ./test.bash --unit       bats suite (tests/bootstrap.bats)
#   ./test.bash --e2e        runs bootstrap.bash on THIS host + assertions.
#                            Destructive: overwrites ~/.claude/settings.json,
#                            rewrites the ~/.bashrc managed block, modifies
#                            global git config, and installs claude / brev
#                            / gh. Only run on a disposable machine.
#   ./test.bash --docker     same as --e2e, but inside a fresh ubuntu:22.04
#                            docker container — safe to run anywhere with
#                            docker available, and the stronger check that
#                            bootstrap works on a bare image.
#   ./test.bash --secrets    gitleaks scan of full history + working tree
#   ./test.bash --all        lint + unit + e2e + secrets, in order
#   ./test.bash -h|--help    print this usage

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

need() {
    command -v "$1" >/dev/null 2>&1 \
        || { echo "test.bash: Missing dependency: $1." >&2; return 1; }
}

run_lint() {
    echo "=== lint ==="
    need bash
    need shellcheck
    bash -n bootstrap.bash
    shellcheck -S warning bootstrap.bash tests/e2e-assertions.bash
}

run_unit() {
    echo "=== unit (bats) ==="
    need bats
    need python3
    bats tests/bootstrap.bats
}

run_e2e() {
    echo "=== e2e (runs bootstrap.bash on this host — DESTRUCTIVE) ==="
    # bootstrap.bash's install_base_deps step installs curl / python3 /
    # git / sudo / ca-certificates itself, so we only need bash here.
    need bash
    : "${GIT_AUTHOR_NAME:=CI Bot}"
    : "${GIT_AUTHOR_EMAIL:=ci@example.com}"
    : "${AAB_CLAUDE_CODE_MODEL:=claude-opus-4-7}"
    : "${AAB_CLAUDE_CODE_INFERENCE_PROVIDER:=anthropic}"
    export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL \
           AAB_CLAUDE_CODE_MODEL AAB_CLAUDE_CODE_INFERENCE_PROVIDER

    bash bootstrap.bash
    bash tests/e2e-assertions.bash

    # Re-run and re-assert to verify idempotency.
    bash bootstrap.bash
    bash tests/e2e-assertions.bash

    # Exercise the provider-switch function. The default Ubuntu ~/.bashrc
    # returns early for non-interactive shells, so extract just the
    # managed block and source that to get at the function.
    local block
    block=$(mktemp)
    awk '/^# >>> autonomous-agent-bootstrap >>>$/,/^# <<< autonomous-agent-bootstrap <<<$/' \
        "$HOME/.bashrc" > "$block"
    # No '-u' here: claude_code_switch_inference_provider re-sources
    # ~/.bashrc at the end, and the default Ubuntu root bashrc references
    # $PS1 unconditionally — which is unset in this non-interactive shell.
    bash -c "
        set -eo pipefail
        # shellcheck disable=SC1090
        . '$block'
        claude_code_switch_inference_provider third-party
        grep -q 'AAB_CLAUDE_CODE_INFERENCE_PROVIDER=\"third-party\"' \"\$HOME/.bashrc\"
        claude_code_switch_inference_provider anthropic
        grep -q 'AAB_CLAUDE_CODE_INFERENCE_PROVIDER=\"anthropic\"' \"\$HOME/.bashrc\"
    "
    rm -f "$block"
    echo "=== e2e passed ==="
}

run_docker_e2e() {
    echo "=== docker e2e (bootstrap in fresh ubuntu:22.04 container) ==="
    need docker
    # Mount the repo read-only and copy it inside the container so the
    # bootstrap works against a pristine tree it can write into.
    # Forward GITHUB_TOKEN (if set) so the Brev installer's release-info
    # call to api.github.com isn't rate-limited in CI; -e X without a value
    # is a no-op when the caller doesn't export it.
    docker run --rm \
        -e GITHUB_TOKEN \
        -v "$HERE:/src:ro" \
        ubuntu:22.04 \
        bash -c 'set -euo pipefail
            cp -r /src /work
            cd /work
            ./test.bash --e2e'
    echo "=== docker e2e passed ==="
}

run_secrets() {
    echo "=== secret scan (gitleaks) ==="
    need gitleaks
    gitleaks detect --source . --redact --verbose --exit-code 1
    gitleaks detect --source . --no-git --redact --verbose --exit-code 1
}

usage() {
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

if [ $# -eq 0 ]; then
    run_lint
    run_unit
    exit 0
fi

for arg in "$@"; do
    case "$arg" in
        --lint)    run_lint ;;
        --unit)    run_unit ;;
        --e2e)     run_e2e ;;
        --docker)  run_docker_e2e ;;
        --secrets) run_secrets ;;
        --all)
            run_lint
            run_unit
            run_e2e
            run_secrets
            ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "test.bash: Unknown arg: $arg." >&2
            usage >&2
            exit 2
            ;;
    esac
done
