# Shared Windows base disk: local validation, 2026-11-03

## Status

**Two simultaneous Windows guests ran from one base, and two test runs ran at
once in one guest; both are measured here.** The simultaneous guests are
recorded on
[#64](https://github.com/antimatter-studios/fs-windows-test-harness/issues/64#issuecomment-6602521544):
both booted and shut down cleanly, and the base's disk, UEFI files, `ssh-key`
and `vm.json` kept the same SHA-256. The sections down to "Same-guest sharing"
are the earlier single-guest run. The rule that follows from all of it is in
[docs/qemu-vm.md](../../qemu-vm.md#one-guest-several-test-runs).

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

## Same-guest measurement

Run on one guest at 4096 MiB and 2 CPUs, beside another worker's Linux VM: each
proof run recorded one, and the rust-fs-ntfs pair started only with a free VM
slot. The raw results are in [same-guest.json](same-guest.json). No software
was installed on the host or the base. The base's hashes matched before and
after each proof run.

**Why the proof stopped in #64.** `tests/shared-base-live.py` read each run's
status from `test-matrix.json`. The harness never writes that file: the runner
writes `test-diagnostics/matrix/results.json`. Both runs had passed, so the
check was wrong and the runs were not. It now reads `results.json`.

**Do two runs overlap?** Yes. Three pairs of `run-tests.sh` runs with the WinFsp
probe overlapped for 0.72, 0.40 and 0.43 seconds of guest time, and each
verified 100 files on its own drive letter. The probe is short, so a real
matrix was also run: rust-fs-ntfs at `ae8283d6`, filter `repeat-mount` (three
scenarios, `max_parallel = 4`), from two checkouts into `C:/fswth/pair-a` and
`C:/fswth/pair-b`, with a private `HARNESS_DIR` each.

| Run | Wall | Result |
| --- | ---: | --- |
| One matrix alone | 117.6 s | 3 of 3 passed |
| Two at once, first to finish | 155.6 s | 3 of 3 passed |
| Two at once, second to finish | 317.0 s | 3 of 3 passed |

Scenario windows overlapped for 132 seconds. No disk image stayed attached
afterwards. The pair took longer than two runs one after the other (235.2 s),
measured once. Of the 317.0 s, 218 s is a single `win-chkdsk` step in one
scenario. A step of that size also appears with one matrix alone, in the
[2026-10-10 run](../qemu-ntfs-macos-2026-10-10/results.json) (216.9 s), so this
stall is not shown to come from sharing. The other scenarios still took about
1.4 times as long as alone.

**Do they collide?** Only on a shared letter or directory. Across three rounds,
all 6 pairs on disjoint letters or directories kept their own contents. Each
of 6 second mounts onto a letter or directory already in use exited nonzero
(183 for a drive letter, 5 for a directory), and the first run's process and
contents were unaffected. In the rust-fs-ntfs pair, all 6 scenarios passed on
the letters Windows assigned.

**What happens to the other run when one fails?** It passes.

| The failing run | Pairs | Failing run | Other run | Failing run's drive afterwards |
| --- | ---: | --- | --- | --- |
| Throws, with both mounted | 2 | `failed` | `passed`, 100 files verified | free |
| PowerShell ended by `Stop-Process`, with both mounted | 2 | `failed` | `passed`, 100 files verified | free |

In the abrupt case no `finally` ran, and memfs did not hold the letter when it
was checked afterwards.

One earlier attempt at the abrupt case shows nothing about sharing, and is left
out of the table. Its harness process on the host ended with `Killed: 9` before
reaching the guest, for a reason not established. Its peer then failed waiting
for it, because the probe's two runs wait for each other to mount. The proof
now reports a run that never mounted as no result rather than as a collision.

**Not measured:** a guest crash or reboot during a pair, disk exhaustion by one
run, a pair at other sizes, or a repeat of the rust-fs-ntfs pair.
