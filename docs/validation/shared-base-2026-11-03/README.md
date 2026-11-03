# Shared Windows base disk: partial local validation, 2026-11-03

## Status

**Two simultaneous Windows guests have not been run. One real Windows
shared-base guest has been run and stopped.** This is partial evidence for
#64, not completion of its acceptance criteria. The remaining check needs a
dedicated window with two free VM slots; no unrelated VM was stopped and a
third VM was never started.

The existing `~/.local/share/fs-windows-test-harness/arm64` installation was
used as the original base. It was not rebuilt, flattened, copied, or modified.
Instance state and raw measurements are under
`$HOME/tmp/constellation-loop/win-64`, outside the checkout. No software was
installed and Docker was not started.

## Verified locally

- The existing 68 VM-free lifecycle tests passed before the change. Four
  new regression tests failed because `instance` was not a recognized
  lifecycle action. The same failure was read back from the CI artifact of
  [run 41613387469](https://github.com/antimatter-studios/fs-windows-test-harness/actions/runs/41613387469)
  at commit `038c481270a743fe8458c49cb71071d1004ea696`: 72 tests, four errors,
  each naming the missing `instance` action. The run completed with failure.
- The implementation passes 77 VM-free lifecycle tests. The four red tests
  and their fixture/helper methods are unchanged; five additional safety
  tests cover stale disk modes, direct base-writing entry points, occupied
  targets, missing resources and nested instances.
- The independent `qemu-img`/`qemu-io` oracle passed against two real qcow2
  overlays of a fresh 8 MiB synthetic disk, without booting a VM. Writes of
  `0xa1` and `0xb2` were read back from their respective overlays, while the
  base retained its original `0x42` pattern and full SHA-256 hash. Both image
  metadata records pointed to the same absolute backing path. This proves
  the overlay write behavior, not the missing two-Windows-VM boot criterion.
- One Windows ARM64 guest booted over HVF, with two vCPUs and 4096 MiB of
  configured guest memory, from the original base through a new instance
  state directory. Another worker's Linux VM was also running. Windows SSH
  became ready in **32.551 seconds**. QMP reported both backing-file nodes
  for the original disk as `ro: true`. The guest wrote and read its own
  sentinel file. Shutdown completed cleanly and removed its boot overlay and
  private variables. The exact Windows QEMU PID was 59304; it is stopped.
- Full SHA-256 hashes of the original disk, firmware code, firmware variables,
  configuration and SSH key matched before and after that guest. The disk's
  hash was and remains
  `dc36ba210f41c74a6d671983a06e918370d0ae42ccde406771917c6bcc515935`.
  Its file size is 24,313,790,464 bytes; no second copy was made.

The allocated regular-file bytes for that instance were:

| Point | Boot disk overlay | Private UEFI variables | Total instance files |
| --- | ---: | ---: | ---: |
| SSH ready | 41,947,136 | 67,108,864 | 109,084,672 |
| After sentinel write/read | 42,995,712 | 67,108,864 | 110,133,248 |
| Before shutdown | 46,141,440 | 67,108,864 | 113,278,976 |

These are allocated bytes (`st_blocks * 512`), not the guest's virtual disk
capacity. Directory metadata and the small runtime socket directory are not
included. The disk and variables are discarded at `down`; the remaining SSH
key, configuration, wrappers and logs occupy 28,672 allocated bytes.

`vm_stat` reported a 16,384-byte page size. Raw free pages, excluding inactive
and otherwise reclaimable memory, corresponded to 14,843,904 bytes before
boot, 444,399,616 bytes with the guest ready, 194,052,096 bytes after the
mount probes, and 70,598,656 bytes after shutdown. The host was busy with
other workers, so these are observed host snapshots, not the guest's memory
cost and not a controlled memory benchmark. Raw output is retained in the
local `single/measurement.json`.

## Same-guest sharing: evidence and limits

The initial guest ran three rounds each of disjoint WinFsp X:/Y: mounts and
disjoint directory mounts under independent `C:/fswth/<name>` workdirs. All
six pairs verified separate sentinel contents while both memfs processes
were mounted. The six deliberately conflicting second mounts exited without
changing the first run's sentinel. However, Windows PowerShell returned a
null `Process.ExitCode` in that initial probe. **Those collision results are
preliminary, not a verified nonzero-exit assertion.** The retained process
handle and explicit non-null/nonzero assertion were added afterward; no
original CI regression assertion was changed or weakened.

The opt-in proof now also runs three pairs of actual `run-tests.sh`
invocations, each with separate workdirs and X:/Y: mounts, verifies 100 files
per run, and requires overlapping guest-side timestamps. This strengthened
probe has not yet been run locally because both VM slots became occupied by
unrelated Linux VMs. It is part of the remaining acceptance command below.

Separate workdirs permit independent leases, but do not reserve VM-global
drive letters or shared directory mountpoints. `max_parallel = "drive-letters"`
counts free letters without reserving them, and `exclusive_group` is scoped
to a single runner process. Independent consumers therefore still need
disjoint drive letters, mountpoints, images, staging and diagnostics. Use
separate VM instances when those resources cannot be partitioned. Two
separate `local-vm.py exec` calls against the same state are refused by its
operation lock; the experiment intentionally starts both harness commands
inside one explicit proof operation.

## Remaining check

When there are no other running QEMU VMs on this MacBook, run the following
from the finished branch with an existing Rust toolchain that supports the
runner's Cargo lockfile. A fresh scratch directory is required. Do not run
`prepare`, `provision`, or `down --save` on the original installation.

```sh
pgrep -fl 'qemu-system-' | grep /opt/homebrew/bin/qemu
RUSTUP_TOOLCHAIN=1.95.0 python3 -u -B tests/shared-base-live.py \
  --base "$HOME/.local/share/fs-windows-test-harness/arm64" \
  --state-root "$HOME/tmp/constellation-loop/win-64/pair-final"
```

The script refuses to exceed two host VMs, boots two Windows instances from
the same original disk, verifies read-only backing nodes and disjoint guest
writes, measures each boot and overlay plus free memory, runs the strengthened
same-guest experiments, stops both guests in `finally`, and compares all base
hashes. Read `pair-final/measurement.json` and the consumer run logs. Only
after that succeeds should #64 be closed with `Fixes #64`. Until then the
pull request is `Part of #64`.
