#!/usr/bin/env bash
# tests/vm-decision.sh -- run-tests.sh decides whether a run needs the VM from
# the same scenarios the runner will run.
#
# run-tests.sh chooses before the runner starts: a run that uses the VM gets
# the preflight, the VM-workdir lock and the ship phase, and any other run gets
# none of them. The runner resolves a filter on its own afterwards
# (runner/src/bin/run-matrix.rs): a filter matching any scenario name selects
# by name, and only a filter matching none is looked up in `[groups]`. When the
# two disagree the run still starts, so VM scenarios run with no lock and with
# whatever scripts the guest last held, and nothing reports the disagreement.
#
# Every case runs the real run-tests.sh with the same flags and a different
# filter, against a stand-in `ssh` that records what reached the VM. The
# stand-in `cargo` records that the runner started and what it was asked for.
#
# Compatible with macOS bash 3.2. Needs python3 (as run-tests.sh does).

set -uo pipefail

HARNESS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fswth-vm-decision.XXXXXX")"
trap 'rm -r "${WORK_DIR}"' EXIT

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

# ── stand-ins ───────────────────────────────────────────────────
BIN="${WORK_DIR}/bin"
mkdir -p "${BIN}"

cat > "${BIN}/ssh" <<'PY'
#!/usr/bin/env python3
# Stand-in for ssh to the Windows VM. Each call adds one line to the journal:
# `preflight`, a VM-lock action, or `Invoke <command>` for a guarded command.
import base64, json, os, re, sys

argv = sys.argv[1:]
command = argv[-1] if argv else ""
entry = "other"
if command == "echo OK":
    entry = "preflight"
    print("OK")
else:
    encoded = re.search(r"-EncodedCommand\s+(\S+)", command)
    if encoded:
        script = base64.b64decode(encoded.group(1)).decode("utf-16le")
        for blob in re.findall(r"FromBase64String\('([A-Za-z0-9+/=]+)'\)", script):
            try:
                params = json.loads(base64.b64decode(blob))
                entry = (params["action"] + " " + params["command"]).strip()
                break
            except Exception:
                continue
    if entry == "Acquire":
        print("[run-tests] VM matrix lock acquired: stand-in")

with open(os.environ["STAND_IN_JOURNAL"], "a") as journal:
    journal.write(entry.replace("\n", " ") + "\n")

# A tar pipe writes to a call with no -n; leaving it unread would break the pipe.
if "-n" not in argv:
    sys.stdin.buffer.read()
PY

cat > "${BIN}/scp" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat > "${BIN}/cargo" <<'SH'
#!/usr/bin/env bash
echo "runner $*" >> "${STAND_IN_JOURNAL}"
exit 0
SH
chmod +x "${BIN}/ssh" "${BIN}/scp" "${BIN}/cargo"

# ── a consumer with VM, host-only and recipe-less scenarios ─────
make_consumer() {
    local dir="$1"
    mkdir -p "${dir}"
    cat > "${dir}/fs-windows-test-harness.toml" <<'TOML'
[project]
name        = "vm-decision-fixture"
matrix_path = "test-matrix.json"

[vm]
host      = "${VM_HOST}"
workdir   = "${VM_WORKDIR}"
image_dir = "images"

[ops.on-vm]
host        = "vm"
command     = "Start-Sleep -Seconds 1"
expect_exit = 0

[ops.on-host]
host        = "host"
command     = "true"
expect_exit = 0

[groups]
vm-group    = ["vm-one", "vm-two"]
host-group  = ["host-one", "host-two"]
mixed-group = ["host-one", "vm-one"]
empty-group = ["no-recipe"]
# Each of these names matches a scenario name, so the runner never expands it.
host        = ["vm-one"]
vm          = ["host-one"]
no-rec      = ["vm-one"]
TOML
    cat > "${dir}/test-matrix.json" <<'JSON'
{
  "scenarios": {
    "vm-one":    { "status": "pending", "recipe": [ { "op": "on-vm" } ] },
    "vm-two":    { "status": "pending", "recipe": [ { "op": "on-vm" } ] },
    "host-one":  { "status": "pending", "recipe": [ { "op": "on-host" } ] },
    "host-two":  { "status": "pending", "recipe": [ { "op": "on-host" } ] },
    "no-recipe": { "status": "pending", "recipe": [] }
  }
}
JSON
}

# ── one run ─────────────────────────────────────────────────────
# run_filter FILTER: sets DIR and RC. An empty FILTER passes no filter at all.
DIR=""
RC=0
CASE=0
run_filter() {
    local filter="$1"
    CASE=$((CASE + 1))
    DIR="${WORK_DIR}/case-${CASE}"
    make_consumer "${DIR}"
    : > "${DIR}/journal"
    (
        cd "${DIR}" || exit 99
        PATH="${BIN}:${PATH}" STAND_IN_JOURNAL="${DIR}/journal" \
        FSWTH_REMOTE_TIMEOUT_SECONDS=30 \
            bash "${HARNESS_ROOT}/scripts/run-tests.sh" ${filter:+"${filter}"} \
                --vm-host=tester@stand-in --vm-workdir=C:/fswth-vm-decision
    ) > "${DIR}/out.txt" 2>&1 < /dev/null
    RC=$?
}

evidence() {
    printf 'rc=%s; journal: %s; output: %s' "${RC}" \
        "$(cut -c1-60 "${DIR}/journal" | tr '\n' '|')" \
        "$(grep -E '^\[(run-tests|ship)\]' "${DIR}/out.txt" | tr '\n' '|')"
}

# The first journal line holding the text, or nothing.
journal_line() { grep -n -- "$1" "${DIR}/journal" | head -1 | cut -d: -f1; }

# expect_vm_run LABEL: the lock is held around the ship and the run.
expect_vm_run() {
    local label="$1" preflight acquire tar runner release
    preflight="$(journal_line '^preflight')"
    acquire="$(journal_line '^Acquire')"
    tar="$(journal_line '^Invoke tar -xf')"
    runner="$(journal_line '^runner ')"
    release="$(journal_line '^Release')"
    if [[ "${RC}" -eq 0 && -n "${preflight}" && -n "${acquire}" && -n "${tar}" \
          && -n "${runner}" && -n "${release}" ]] \
        && (( preflight < acquire && acquire < tar && tar < runner && runner < release )) \
        && grep -q '^\[ship\] harness scripts/vm/' "${DIR}/out.txt"; then
        ok "${label}: preflight, lock, ship, run, release, in that order"
    else
        bad "${label}: preflight, lock, ship, run, release, in that order ($(evidence))"
    fi
}

# expect_host_run LABEL: the runner started and nothing reached the VM.
expect_host_run() {
    local label="$1"
    if [[ "${RC}" -eq 0 && -n "$(journal_line '^runner ')" ]] \
        && ! grep -qv '^runner ' "${DIR}/journal" \
        && ! grep -qE '^\[ship\]|VM lock|preflight' "${DIR}/out.txt"; then
        ok "${label}: the runner ran and nothing reached the VM"
    else
        bad "${label}: the runner ran and nothing reached the VM ($(evidence))"
    fi
}

# expect_filter_passed FILTER LABEL: the runner is the one that expands a group.
expect_filter_passed() {
    if grep -qE "^runner .* $1\$" "${DIR}/journal"; then
        ok "$2: the runner is given the filter '$1'"
    else
        bad "$2: the runner is given the filter '$1' ($(evidence))"
    fi
}

# ── a group is what the runner runs ─────────────────────────────
run_filter vm-group
expect_vm_run "a group of VM scenarios"
expect_filter_passed vm-group "a group of VM scenarios"

run_filter host-group
expect_host_run "a group of host-only scenarios"
expect_filter_passed host-group "a group of host-only scenarios"

run_filter mixed-group
expect_vm_run "a group holding one VM scenario among host ones"

run_filter empty-group
expect_host_run "a group of scenarios with no recipe"

# ── a scenario name beats a group of the same name, as in the runner ────
run_filter host
expect_host_run "'host' names host scenarios and a group of VM ones"

run_filter vm
expect_vm_run "'vm' names VM scenarios and a group of host ones"

run_filter no-rec
expect_host_run "'no-rec' names a recipe-less scenario and a group of VM ones"

# ── filters that name no group behave as they did ───────────────
run_filter vm-on
expect_vm_run "a substring of a VM scenario's name"

run_filter host-on
expect_host_run "a substring of a host scenario's name"

run_filter ""
expect_vm_run "no filter, on a matrix holding VM scenarios"

run_filter matches-nothing
expect_host_run "a filter matching no scenario and no group"

echo "==============================================================="
echo "  results: ${PASS} passed, ${FAIL} failed"
echo "==============================================================="
[[ ${FAIL} -eq 0 ]]
