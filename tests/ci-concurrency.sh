#!/usr/bin/env bash
# tests/ci-concurrency.sh -- a red: pull request's run is never cancelled by
# the push that adds its fix.
#
# A pull request opens holding only its failing test, with a title that starts
# "red:", and the CI run of that commit is its red evidence (agent-core v8).
# The fix is pushed to the same branch after the title loses "red:". ci.yml
# cancels a pull request's run when a newer push arrives, so without an
# exception the fix push would cancel the red run, often before it has failed.
# So while the title starts "red:", each push is a group of its own commit and
# is never cancelled: keyed by the commit and not only by the pull request,
# because GitHub keeps one pending run per group even with cancelling off, and
# a second push sharing the group would replace a red run waiting for a runner.
# Every other pull request run still cancels the one it supersedes.
#
# Compatible with macOS bash 3.2.

set -uo pipefail

HARNESS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

block="$(awk '/^concurrency:/{f=1;next} f&&/^[^ ]/{exit} f{sub(/^[ \t]+/,""); print}' \
    "${HARNESS_ROOT}/.github/workflows/ci.yml")"

expect() {
    case "${block}" in
        *"$1"*) ok "$2" ;;
        *) bad "$2" ;;
    esac
}

expect "cancel-in-progress: \${{ github.event_name == 'pull_request' && !startsWith(github.event.pull_request.title, 'red:') }}" \
    "ci.yml cancels only a pull request's superseded run, never a red: pull request's"
expect "github.event.pull_request.number || github.ref" \
    "ci.yml keeps one group per pull request, and per ref outside one"
expect "startsWith(github.event.pull_request.title, 'red:') && format('-red-{0}', github.event.pull_request.head.sha) || ''" \
    "ci.yml gives each push to a red: pull request a group of its own commit"

if [[ "${FAIL}" -eq 0 ]]; then
    printf 'ci-concurrency: %s checks passed\n' "${PASS}"
    exit 0
fi
printf 'ci-concurrency: %s of %s checks failed\n' "${FAIL}" "$((PASS + FAIL))" >&2
exit 1
