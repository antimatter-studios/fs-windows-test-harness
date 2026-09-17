#!/usr/bin/env bash
# reset-non-passed.sh -- reset every non-`passed-*` scenario back to
# `pending` so a new pass can re-claim them. Idempotent. Serialised
# with claims and status updates under the lock in _matrix_txn.py.
#
# Usage: bash <harness>/scripts/reset-non-passed.sh
#
# Env (optional):
#   MATRIX_PATH   absolute path to the test-matrix.json to mutate
#                 (default: $PWD/test-matrix.json).

set -euo pipefail
WORK_LIST="${MATRIX_PATH:-${PWD}/test-matrix.json}"
if [[ ! -f "${WORK_LIST}" ]]; then
    echo "missing work list: ${WORK_LIST}" >&2
    exit 2
fi

exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_matrix_txn.py" \
    reset "${WORK_LIST}"
