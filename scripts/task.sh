#!/usr/bin/env bash
# task.sh LABEL LOG-NAME MAX-LINES MAX-BYTES -- COMMAND [ARG...]
#
# How this repository's own chore tasks run: QUIETLY and under a budget,
# through output-budget.sh. The whole run goes to tmp/logs/<LOG-NAME>.log; a
# pass prints one verdict line naming the log, a failure prints the tail of it,
# and a run that passed but printed more than its budget fails with status 65.
#
# It exists only to turn chore's arguments into output-budget.sh's: chore puts
# whatever follows `--` in CLI_ARGS, and `chore test -- --verbose` (or -v) is
# the way to ask for the whole run on the terminal. FWTH_VERBOSE=1 does the
# same. Neither lifts the budget: the log is the same size either way.
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
    *" --verbose "*|*" -v "*) export FWTH_VERBOSE=1 ;;
esac

exec "$REPO/scripts/output-budget.sh" \
    --log "$REPO/tmp/logs/$LOG_NAME.log" \
    --max-lines "$MAX_LINES" \
    --max-bytes "$MAX_BYTES" \
    --label "$LABEL" \
    -- "$@"
