#!/usr/bin/env bash
# update-scenario-status.sh -- atomically update a scenario's status.
#
# Generic, FS-agnostic. Serialised with every other matrix mutation
# under the lock in _matrix_txn.py; see claim-scenario.sh.
#
# Usage:
#   bash <harness>/scripts/update-scenario-status.sh \
#       <scenario-name> <new-status> [<evidence-link>]
#
# Examples:
#   ... basic-ro-list passed-agent-3f7c-2026-05-07
#   ... basic-rw-write failed-agent-3f7c-... "$DIAG_DIR/run-..."
#   ... xattr-getxattr blocked-needs-getxattr-cli
#
# Env (optional):
#   MATRIX_PATH   absolute path to the test-matrix.json to mutate
#                 (default: $PWD/test-matrix.json).

set -euo pipefail

SCENARIO="${1:-}"
NEW_STATUS="${2:-}"
EVIDENCE="${3:-}"
if [[ -z "${SCENARIO}" || -z "${NEW_STATUS}" ]]; then
    echo "usage: $0 <scenario-name> <new-status> [<evidence-link>]" >&2
    exit 2
fi

WORK_LIST="${MATRIX_PATH:-${PWD}/test-matrix.json}"
if [[ ! -f "${WORK_LIST}" ]]; then
    echo "missing work list: ${WORK_LIST}" >&2
    exit 2
fi
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_matrix_txn.py" \
    status "${WORK_LIST}" "${SCENARIO}" "${NEW_STATUS}" "${EVIDENCE}"
