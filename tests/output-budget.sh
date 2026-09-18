#!/usr/bin/env bash
#
# output-budget.sh -- the budget refuses a loud run, and never hides a failing
# one.
#
# The script exists because "keep the output quiet" as a convention lasts about
# a week. The properties worth pinning are the ones that make it safe to rely
# on: the COMMAND's status is what escapes (a `| tee` that reported tee's status
# is the defect that makes a red suite read green), a failure shows the tail
# rather than the budget complaint, and a passing-but-loud run is told apart
# from a failing one by its own exit code.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
B="$REPO/scripts/output-budget.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass=0; fail=0

ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
check_eq() { [ "$1" = "$2" ] && ok "$3" || bad "$3 (got '$1', want '$2')"; }
check_contains() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (output: ${1//$'\n'/ | })" ;; esac; }

run() { # run <log-name> <args...> -- sets $out and $rc
    local log="$work/$1"; shift
    out="$("$B" --log "$log" "$@" 2>&1)"; rc=$?
}

unset FWTH_VERBOSE
echo "output-budget.sh"

# ---------------------------------------------------------------- within
run a.log --max-lines 5 --label demo -- sh -c 'echo one; echo two'
check_eq "$rc" 0 "a run inside its budget succeeds"
check_contains "$out" "demo: ok (2 lines" "and says what it printed"
check_contains "$out" "$work/a.log" "and names the log"
case "$out" in *one*) bad "a passing run keeps its output off the terminal" ;; *) ok "a passing run keeps its output off the terminal" ;; esac

# ------------------------------------------------------------- over lines
run b.log --max-lines 2 --label demo -- sh -c 'for i in 1 2 3 4; do echo "line$i"; done'
check_eq "$rc" 65 "a passing run over its line budget exits 65"
check_contains "$out" "printed 4 lines (budget 2)" "and says by how much"
check_eq "$(wc -l < "$work/b.log" | tr -d ' ')" 4 "while the log still holds everything"

# ------------------------------------------------------------- over bytes
run c.log --max-bytes 4 --label demo -- sh -c 'echo 12345678'
check_eq "$rc" 65 "a byte budget is enforced too"

# ------------------------------------------------- a failure is not a budget
# The command's status must escape unchanged, and the tail must be shown: a
# failing run that printed only the budget complaint would be worse than no
# budget at all.
run d.log --max-lines 1 --tail 2 --label demo -- sh -c 'echo noise; echo "the real error"; exit 3'
check_eq "$rc" 3 "a failing command exits with ITS status, not the budget's"
check_contains "$out" "the real error" "and its tail is shown"
case "$out" in
    *"budget"*) bad "a failure does not complain about the budget" ;;
    *) ok "a failure does not complain about the budget" ;;
esac

# ------------------------------------------------------------------ verbose
run e.log --label demo --verbose -- sh -c 'echo streamed'
check_eq "$rc" 0 "verbose succeeds"
check_contains "$out" "streamed" "and streams the output"
check_eq "$(cat "$work/e.log")" "streamed" "while still writing the log"

run f.log --label demo --verbose -- sh -c 'echo oops; exit 7'
check_eq "$rc" 7 "verbose reports the command's status, not tee's"

out="$(FWTH_VERBOSE=1 "$B" --log "$work/g.log" --max-lines 1 --label demo -- sh -c 'echo a; echo b' 2>&1)"; rc=$?
check_eq "$rc" 65 "FWTH_VERBOSE streams but does not exempt a run from its budget"
check_contains "$out" "a" "and FWTH_VERBOSE does stream"

# ------------------------------------------------------------------ misuse
out="$("$B" --max-lines 1 -- true 2>&1)"; rc=$?
check_eq "$rc" 2 "a missing --log is refused"
out="$("$B" --log "$work/h.log" 2>&1)"; rc=$?
check_eq "$rc" 2 "a missing command is refused"

# ------------------------------------------------------- no budget, no limit
run i.log --label demo -- sh -c 'i=0; while [ $i -lt 200 ]; do echo "$i"; i=$((i+1)); done'
check_eq "$rc" 0 "without a budget a long run is allowed"

# ------------------------------------------------ every task is budgeted
# The rule, checked against this repository's own chores.yml: each task that
# runs a suite goes through output-budget.sh with two non-zero budgets. A task
# added later without one is exactly how "quiet" rots, so it fails here.
for task in lint test state-machine config; do
    block="$(awk -v t="  $task:" '
        $0 == t { inside = 1; next }
        inside && /^  [a-z][a-z:_-]*:$/ { inside = 0 }
        inside { print }
    ' "$REPO/chores.yml")"
    if [ -z "$block" ]; then bad "chores.yml has a '$task' task"; continue; fi
    # scripts/task.sh LABEL LOG MAX-LINES MAX-BYTES: a zero in either budget
    # is "no budget" to output-budget.sh, which is the shape refused here.
    if printf '%s\n' "$block" | grep -Eq 'scripts/task\.sh +[^ ]+ +[^ ]+ +[1-9][0-9]* +[1-9][0-9]*'; then
        ok "chore $task runs under a line and a byte budget"
    else
        bad "chore $task runs under a line and a byte budget"
    fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
