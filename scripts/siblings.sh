#!/usr/bin/env bash
#
# siblings.sh — put rust-fs-core where this repository expects to find it.
#
# The only sibling this harness has. It is not a dependency of the runner or
# of any consumer: it supplies ONE file, scripts/output-budget.sh, the
# family's canonical output-budget wrapper, which this repository is
# deliberately not a second copy of. scripts/resolve-output-budget.sh says
# where it looks and why.
#
# THE PIN IS A FLOOR, NOT A TARGET. One checkout of core is shared by every
# crate on the machine, so a task that checks out its own pin rewinds
# somebody else's work — measured in the driver family on 2026-09-22, where
# the oldest pin in the family won and a sibling two commits ahead was
# silently reset. So: a checkout that already contains the pinned ref is left
# exactly as it is, on whatever branch it is on. A checkout below the floor is
# fast-forwarded only when `main` is what is checked out and the tree is
# clean. Anything else is reported for a person to resolve, because this is
# not the task's checkout to hijack.
#
# FS_CORE_ROOT overrides where core is, and this script will populate that
# path too — which is how CI uses it, a runner having no sibling directory.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URL="${FS_CORE_URL:-https://github.com/antimatter-studios/rust-fs-core.git}"
REF="${FS_CORE_REF:?siblings.sh: FS_CORE_REF must name the pinned ref}"

DIR="$("$REPO/scripts/resolve-output-budget.sh" --core-dir)"
[ -n "$DIR" ] || { echo "siblings.sh: could not work out where rust-fs-core belongs" >&2; exit 1; }

if [ ! -d "$DIR/.git" ]; then
    echo "siblings: cloning rust-fs-core into $DIR"
    git init --quiet "$DIR"
    git -C "$DIR" remote add origin "$URL"
    # Neither --depth 1 nor a detached checkout of the tag: the floor check
    # below needs history to answer, and a detached HEAD reads as a deliberate
    # state, so nothing complains as it goes stale.
    git -C "$DIR" fetch --quiet --tags origin main
    git -C "$DIR" checkout --quiet -B main origin/main
fi

if [ -n "$(git -C "$DIR" status --porcelain)" ]; then
    echo "siblings: rust-fs-core has uncommitted changes — refusing to move it." >&2
    exit 1
fi

git -C "$DIR" fetch --quiet --tags origin main
current="$(git -C "$DIR" rev-parse --abbrev-ref HEAD)"
if git -C "$DIR" merge-base --is-ancestor "$REF" HEAD; then
    echo "siblings: rust-fs-core at or ahead of $REF (on $current)"
elif [ "$current" = "main" ] && git -C "$DIR" merge --ff-only --quiet origin/main 2>/dev/null; then
    echo "siblings: rust-fs-core fast-forwarded to $(git -C "$DIR" rev-parse --short HEAD)"
else
    echo "siblings: rust-fs-core is on '$current' and below $REF; this task will not move it." >&2
    echo "          It is one checkout shared by every repository here — move it yourself." >&2
    exit 1
fi
