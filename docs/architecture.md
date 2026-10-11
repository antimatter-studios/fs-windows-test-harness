# Architecture

Three parts: **an orchestrator on the host** (macOS, Linux or WSL2) that
runs every scenario, **a Windows guest** that executes the steps sent to it
over SSH, and **the consumer's `test-matrix.json`**, the shared state file.

## Topology

```
+-- Host (macOS / Linux / WSL2) ----------------------------------+
| <harness>/scripts/run-tests.sh                                  |
|   bootstrap .test-env, SSH preflight                            |
|   take the VM-workdir lease (scripts/vm/matrix-run-lock.ps1)    |
|   ship harness + consumer scripts/vm/ and the driver binary     |
|     (or the source, when [run].vm_build_command is set)         |
|   cargo run --bin run-matrix          <- runs here, on the host |
|                                                                 |
| run-matrix (libtest-mimic, one trial per scenario,              |
|   up to [runner].max_parallel at once)                          |
|   for each recipe step, in order, stopping at the first fail:   |
|     host = "host"              -> a local subprocess            |
|     host = "vm"                -> one ssh command to the guest  |
|     ship-to-vm / ship-to-host  -> scp an image across           |
|   writes test-diagnostics/matrix/ on the host                   |
+-------------------------------+---------------------------------+
                                | ssh / scp, one command per step
                                v
+-- Windows guest ------------------------------------------------+
| OpenSSH with PowerShell as its default shell, and WinFsp        |
| <workdir>/scripts/vm/*.ps1: op scripts, run lock, chkdsk        |
| the driver binary: each op mounts, works and unmounts within    |
|   its own SSH session                                           |
+-----------------------------------------------------------------+
```

Locally the guest is normally the QEMU guest from
[`qemu-vm.md`](qemu-vm.md), reached as `fswth-local` through
`local-vm.py exec --`. [`vm-setup.md`](vm-setup.md) describes a hand-built
VMware guest instead, and CI's `smoke` job uses its own `windows-latest`
runner as the guest. Nothing of the harness runs on the guest between
steps. A mount process dies with the SSH session that started it, so each
Windows-side op is self-contained: `scripts/vm/_lib.ps1` mounts, waits for
the driver's ready line, runs the op and unmounts in a `finally`.

## Parallelism

Scenarios run concurrently, up to `[runner].max_parallel`: a number
(default 1), or `"drive-letters"`, which asks the guest how many drive
letters are free. The runner clamps it to 1–24 and sizes libtest-mimic's
thread pool to match. A scenario that names an `exclusive_group` takes that
group's slot before a global one, so scenarios sharing a scarce resource
run one at a time without holding global slots while they wait. Drive
letters do not guarantee memory: choose a value the guest can hold (the
QEMU guest has 4 GiB). Separate guests are independent.

## Lifecycle: state machine for one scenario

```
   pending
     |
     | claim-scenario.sh "<session>"
     v
   claimed-<session>
     |
     | run-matrix runs its recipe; result.json says passed, failed or errored
     |
     +-- passed  --> update-scenario-status.sh <name> passed-<session> [<diag-dir>]
     +-- failed  --> update-scenario-status.sh <name> failed-<session> [<diag-dir>]
     +-- errored --> update-scenario-status.sh <name> errored-<session> [<diag-dir>]
     +-- (agent decision) --> blocked-needs-<feature>
```

The runner does not write status itself -- agents drive transitions
via the `claim-scenario.sh` / `update-scenario-status.sh` pair, whose
optional third argument records the `evidence_link`. The runner only
writes the diagnostics tree below. A scenario with no recipe is reported
as ignored rather than run.

A scenario **passes** when every step exits with its expected code (a step
whose op `when` predicate is false is skipped). It **fails** when a step
exits with another code or errors: its command could not be built (an
unresolved template reference), could not start, or hit its timeout. The
recipe stops at that step. It is **errored** when the runner could not run
the recipe at all, for example because a step names an op that `[ops]` does
not declare.

## State storage

`test-matrix.json` at the consumer repo root is the single source of
truth. Schema is documented in [`../schemas/test-matrix.schema.json`](../schemas/test-matrix.schema.json).

Every mutation (claim, status update, reset) is one read-modify-write
under an exclusive `flock` on the matrix file
([`scripts/_matrix_txn.py`](../scripts/_matrix_txn.py)), and the new file
is renamed into place before the lock is released. Concurrent claimers
therefore queue rather than race, and none can overwrite another's claim
with a stale copy.

## Diagnostics layout

`run-matrix` runs on the host, so it writes the tree directly under
`<consumer-root>/test-diagnostics/matrix/`, which it clears at the start of
each run:

```
test-diagnostics/
  matrix/
    run-manifest.json     timestamp, host OS, consumer git SHA, project, scenario counts
    results.json          every scenario's result.json, sorted by name
    <scenario-name>/
      result.json         name, status, error (the failing step's output tail), diag_dir, duration_secs
      recipe.json         every executed step's result, and overall_passed
      step-NN/
        step.json         op, host, the resolved command, exit code, expected exit, duration, skip or error
        stdout.txt
        stderr.txt
  vm-lease-heartbeat.log  the VM-workdir lease's renewals
```

`step.json` with its `stdout.txt` and `stderr.txt` is the persistent
contract: an agent walking into a diag dir cold can see exactly which
command ran where, what it printed and how it exited, without re-running
anything. A failing scenario's line in the transcript also carries the last
4 KB of that step's stderr and stdout.

## Concurrency

- **Multiple agents** can claim from the same matrix.json in parallel.
  The locked transaction above prevents two agents taking the same
  scenario.
- **Per guest**: scenarios run up to `max_parallel` at once, with
  `exclusive_group` serialising those that share a resource (see
  [Parallelism](#parallelism)).
- **Per VM workdir**: `run-tests.sh` acquires a renewable lease before
  reinstall, ship, or matrix work. A Windows file-share gate serializes
  acquisition, renewal, and release. A second gate stays held across each
  VM command, so recovery cannot overlap an in-flight mutation. Built-in
  image transfers use owner-scoped staging and a guarded final move.
  Missing or corrupt owner metadata is reclaimed only after the lock
  directory itself has aged past the lease. The orchestrator PID is only
  diagnostic; the VM never probes it. Separate workdirs remain useful for
  running independent matrices at once.

## Re-entrancy

- `reset-non-passed.sh` idempotently resets every non-`passed-*`
  scenario back to `pending`. Use between passes.
- Each Windows-side op unmounts in a `finally`, and a mount that never
  signals ready is stopped with `Stop-Process -Force`, so a failed step
  does not leave its volume mounted for the next one.
- On the QEMU guest, `local-vm.py down` and the next cold `up` return
  the guest to its reset point, discarding anything a run left on its
  disk. Within one boot, runs see what earlier runs left behind.

## Ops model

Behaviour comes from configuration, which is the reason this harness was
extracted. The consumer's `fs-windows-test-harness.toml` declares each op
in `[ops]` as a command template. The runner fills in the
[substitution tokens](vocabulary.md) and runs the command where the recipe
step's `host` says: a local subprocess (`cmd.exe` when the host is
Windows) or one SSH command to the guest's PowerShell. `ship-to-vm` and
`ship-to-host` are built in and copy images with scp through a staging
name guarded by the VM-workdir lease. The harness also ships Windows-side op
scripts (`scripts/vm/win-*.ps1`) and host-side verifiers
(`scripts/host/verify-*.sh`) that a consumer's ops can call.

The runner crate can be used as a library (`Harness::load`,
`run_recipe`), but it has no adapter trait: a driver plugs in through its
CLI binary and the op templates.
