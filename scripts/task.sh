#!/usr/bin/env bash
# task.sh LABEL LOG-NAME MAX-LINES MAX-BYTES -- COMMAND [ARG...]
#
# How this repository's own chore tasks run: QUIETLY and under a budget,
# through rust-fs-core's output-budget.sh. The whole run goes to
# tmp/logs/<LOG-NAME>.log; a pass prints one verdict line naming the log, a
# failure prints a verdict naming the log, its size and the command's status,
# and a run that passed but printed more than its budget fails with status 65.
#
# THE WRAPPER IS NOT IN THIS REPOSITORY. It is rust-fs-core's, resolved at run
# time by scripts/resolve-output-budget.sh — read that file for where it
# looks and why there is no committed copy. A missing core is loud: this task
# fails and names what would provide it, rather than running the suite
# unbudgeted.
#
# This adapter exists to turn chore's arguments into the wrapper's: chore puts
# whatever follows `--` in CLI_ARGS, and `chore test -- --verbose` (or -v) is
# the way to ask for the whole run on the terminal. OUTPUT_BUDGET_VERBOSE=1
# does the same. Neither lifts the budget: the log is the same size either way.
#
# A FAILURE PRINTS NO TAIL BY DEFAULT. The verdict names the log and how many
# lines are in it; `OUTPUT_BUDGET_FAIL_TAIL=40` brings the tail back for a
# person at a terminal. The default is core's, and the reason is the reader
# who pays most for those lines: an agent that re-reads its whole transcript
# on every later step, for a tail that rarely holds the assertion anyway.
#
# The budgets are in chores.yml beside the command each one bounds, and every
# one of them was measured. See the README, "Output: quiet by default".
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[ $# -ge 5 ] || { echo "task.sh: usage: task.sh LABEL LOG MAX-LINES MAX-BYTES -- CMD..." >&2; exit 2; }
LABEL="$1"; LOG_NAME="$2"; MAX_LINES="$3"; MAX_BYTES="$4"; shift 4
[ "${1:-}" = "--" ] && shift
[ $# -gt 0 ] || { echo "task.sh: no command" >&2; exit 2; }

case " ${CLI_ARGS:-} " in
    *" --verbose "*|*" -v "*) export OUTPUT_BUDGET_VERBOSE=1 ;;
esac

# Not `BUDGET="$(...)"` on its own line: that would swallow the resolver's
# status and run the suite with an empty path, which is the silent form of
# exactly the failure this is here to make loud.
if ! BUDGET="$("$REPO/scripts/resolve-output-budget.sh")"; then
    echo "task.sh: cannot run '$LABEL' without the canonical output-budget wrapper." >&2
    exit 1
fi

exec bash "$BUDGET" \
    --log "$REPO/tmp/logs/$LOG_NAME.log" \
    --max-lines "$MAX_LINES" \
    --max-bytes "$MAX_BYTES" \
    --label "$LABEL" \
    -- "$@"
