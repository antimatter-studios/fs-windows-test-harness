#!/usr/bin/env bash
# claim-scenario.sh -- atomic scenario claim from test-matrix.json.
#
# Generic, FS-agnostic. Reads the consumer project's matrix file (path
# resolved via $MATRIX_PATH env var, else <repo-root>/test-matrix.json).
#
# Usage:
#   bash <harness>/scripts/claim-scenario.sh "<session-name>"
#
# Env (optional):
#   MATRIX_PATH   absolute path to the test-matrix.json to mutate
#                 (default: $PWD/test-matrix.json -- run from the
#                 consumer's repo root).
#
# Output:
#   stdout: the claimed scenario name (one line) on success
#   exit 0 -- scenario claimed
#   exit 1 -- no pending scenarios available
#   exit 2 -- usage error / missing work list
#
# Atomicity:
#   The whole read -> pick -> write sequence runs under an exclusive
#   flock(2) on the matrix file (scripts/_matrix_txn.py), and the new
#   file is renamed into place before the lock is released. Concurrent
#   claimers therefore queue rather than race: each one sees every claim
#   made before it, so no scenario is handed out twice and no claim is
#   lost. (An earlier version wrote optimistically and read back to
#   detect a lost race; the read-back was itself unserialised, so two
#   agents could both "win" the same scenario. See CHANGELOG.)

set -euo pipefail

SESSION="${1:-}"
if [[ -z "${SESSION}" ]]; then
    echo "usage: $0 <session-name>" >&2
    exit 2
fi

WORK_LIST="${MATRIX_PATH:-${PWD}/test-matrix.json}"

if [[ ! -f "${WORK_LIST}" ]]; then
    echo "missing work list: ${WORK_LIST}" >&2
    echo "  set MATRIX_PATH or run from the consumer repo root" >&2
    exit 2
fi

exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_matrix_txn.py" \
    claim "${WORK_LIST}" "${SESSION}"
