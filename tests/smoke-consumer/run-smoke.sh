#!/usr/bin/env bash
# run-smoke.sh -- drive the smoke consumer through scripts/run-tests.sh
# and check the verdicts it reports.
#
# Two runs of the real orchestrator, each against a Windows host with
# WinFsp installed:
#
#   1. `smoke-`  scenarios: must exit 0, every scenario `passed` on its
#      FIRST attempt (a retry would hide a flaky harness), every step
#      executed with its diagnostics on disk.
#   2. `canary-` scenarios: must exit non-zero, and the harness must
#      report `failed` at the exact step that was built to fail, for
#      the reason it was built to fail. A harness that cannot go red
#      proves nothing when it is green.
#
# Usage:
#   bash tests/smoke-consumer/run-smoke.sh [run-tests.sh VM flags]
#     e.g. --vm-host=user@vm --ssh-key=~/.ssh/id --vm-workdir=C:/fswth/smoke-consumer
#   With no flags, run-tests.sh uses tests/smoke-consumer/.test-env
#   (prompting to create it on an interactive terminal).
#
# The VM needs WinFsp (`run-tests.sh --reinstall` installs it from
# [vm.packages]) and sshd with PowerShell as its default shell.
#
# Diagnostics: test-diagnostics/{smoke,canary}/ plus the two run logs.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${here}"
run_tests="${here}/../../scripts/run-tests.sh"
out="${here}/test-diagnostics"
rm -rf "${out}/smoke" "${out}/canary"
mkdir -p "${out}"

run_phase() {
    # run_phase <name> <filter> [flags...] -- sets PHASE_RC.
    local name="$1" filter="$2"
    shift 2
    echo "=== ${name}: run-tests.sh ${filter} ==="
    set +e
    bash "${run_tests}" "${filter}" "$@" 2>&1 | tee "${out}/${name}.log"
    PHASE_RC=${PIPESTATUS[0]}
    set -e
    rm -rf "${out:?}/${name}"
    if [[ -d "${out}/matrix" ]]; then
        mv "${out}/matrix" "${out}/${name}"
    fi
    echo "=== ${name}: run-tests.sh exited ${PHASE_RC} ==="
}

# Both phases always run, so one CI log shows both verdicts.
status=0
run_phase smoke smoke- "$@"
python3 "${here}/assert_verdicts.py" pass "${PHASE_RC}" \
    "${here}/test-matrix.json" smoke- "${out}/smoke" "${out}/smoke.log" || status=1

run_phase canary canary- "$@"
python3 "${here}/assert_verdicts.py" canary "${PHASE_RC}" \
    "${here}/test-matrix.json" canary- "${out}/canary" "${out}/canary.log" || status=1

if [[ "${status}" -ne 0 ]]; then
    echo "smoke test FAILED (see assertions above)" >&2
    exit 1
fi
echo "smoke test OK: smoke-* passed first time, canary-* reported failed as designed"
