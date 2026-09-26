#!/usr/bin/env bash
#
# resolve-output-budget.sh — print the path of the canonical output-budget
# wrapper, or fail saying what would provide it.
#
#   FS_CORE_ROOT=/path/to/rust-fs-core scripts/resolve-output-budget.sh
#
# THE WRAPPER BELONGS TO rust-fs-core AND IS NOT COMMITTED HERE. This
# repository carried its own copy of `scripts/output-budget.sh` until
# rust-fs-core#153. A committed copy is a copy that drifts, and this one had:
# its verbose variable was `FWTH_VERBOSE` where the canonical script reads
# `OUTPUT_BUDGET_VERBOSE`, and it printed forty lines of tail on a failure
# where the canonical script prints none. Both repositories were internally
# consistent, nothing compared them, and a consumer reading one harness's
# README got the other's behaviour.
#
# This harness is not a driver: it has no `am-fs-core` dependency and cargo
# cannot be asked where core is, the way a driver crate asks. So core is a
# plain pinned sibling checkout here, and this script is the whole of the
# coupling — a path, resolved at run time, and nothing linked or vendored.
#
# WHERE IT LOOKS, in order, stopping at the first candidate that EXISTS:
#
#   1. $FS_CORE_ROOT, if set and non-empty. Authoritative: a wrong or absent
#      script under it is an error, never a reason to look further. CI sets
#      this, because a GitHub runner has no sibling directory.
#   2. The sibling beside the MAIN working tree. `git rev-parse
#      --git-common-dir` names the main tree from a linked worktree as well
#      as from the main checkout, so an agent working in a worktree resolves
#      the same core as everybody else rather than a second copy of it.
#   3. The sibling beside this checkout, for a plain clone with no git.
#
# A CANDIDATE THAT EXISTS IS THE ANSWER, RIGHT OR WRONG. A present-but-wrong
# core is a fatal error and not a reason to fall through to the next
# candidate: falling through is how a stale checkout gets silently ignored
# and a run reports a wrapper nobody pointed it at.
#
# THE CHECK IS `--version`, NOT A DIGEST. The API version is the contract; a
# SHA-256 pinned in several repositories is the lockstep this arrangement
# removes — core could not fix a typo in a comment without a commit in every
# consumer. The pinned ref lives in chores.yml and the CI workflow, where a
# version pin belongs.
#
# It prints ONE absolute path on stdout and everything else on stderr, so
# `"$(scripts/resolve-output-budget.sh)"` is safe.
#
# `--core-dir` prints where core is, or where it would have to be, WITHOUT
# validating anything. That is what scripts/siblings.sh clones into, so the
# answer to "where does core live" has one definition in this repository
# rather than two that can disagree.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_REL="scripts/output-budget.sh"
EXPECTED_API="rust-fs-core-output-budget 1"

die() {
    printf 'resolve-output-budget.sh: %s\n' "$1" >&2
    shift
    for line in "$@"; do printf '                          %s\n' "$line" >&2; done
    exit 1
}

case "${1:-}" in
    ""|--core-dir) ;;
    *) echo "resolve-output-budget.sh: unknown argument '$1' (only --core-dir)" >&2; exit 2 ;;
esac

# The directory the siblings live in: beside the main working tree, which is
# where a linked worktree's core is too. --path-format=absolute is required,
# not tidiness: without it a main checkout answers a bare `.git` and the
# sibling resolves to `//rust-fs-core`.
sibling_root_from_git() {
    local common
    common="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    [ -n "$common" ] || return 1
    (cd "$common/../.." 2>/dev/null && pwd) || return 1
}

candidate=""
origin=""
preferred=""
if [ -n "${FS_CORE_ROOT:-}" ]; then
    candidate="$FS_CORE_ROOT"
    preferred="$FS_CORE_ROOT"
    origin="FS_CORE_ROOT"
else
    for root in "$(sibling_root_from_git)" "$(cd "$REPO/.." && pwd)"; do
        [ -n "$root" ] || continue
        [ -n "$preferred" ] || preferred="$root/rust-fs-core"
        if [ -d "$root/rust-fs-core" ]; then
            candidate="$root/rust-fs-core"
            origin="the sibling checkout"
            break
        fi
    done
fi

if [ "${1:-}" = "--core-dir" ]; then
    printf '%s\n' "${candidate:-$preferred}"
    exit 0
fi

[ -n "$candidate" ] || die \
    "rust-fs-core is not checked out, and FS_CORE_ROOT is not set." \
    "The output-budget wrapper lives in rust-fs-core and is deliberately" \
    "not committed here — see scripts/resolve-output-budget.sh." \
    "Run 'chore siblings' to clone it beside this checkout, or set" \
    "FS_CORE_ROOT to a rust-fs-core checkout."

script="$candidate/$SCRIPT_REL"
[ -f "$script" ] || die \
    "$origin names '$candidate', which has no $SCRIPT_REL." \
    "That is a rust-fs-core checkout older than v0.2.11, or not a" \
    "rust-fs-core checkout at all. Run 'chore siblings' to move it to the" \
    "pinned ref."

version="$(bash "$script" --version 2>/dev/null)"
[ "$version" = "$EXPECTED_API" ] || die \
    "$script does not answer the output-budget API this repository speaks." \
    "expected: $EXPECTED_API" \
    "got:      ${version:-<nothing; the script has no --version>}" \
    "Run 'chore siblings' to move rust-fs-core to the pinned ref."

printf '%s\n' "$script"
