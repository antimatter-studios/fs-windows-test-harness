# Windows VM sizes: partial measurements, 2026-11-03

## Status

**Not finished, so the defaults stay at 4096 MiB and 2 CPUs.** Only 3072 MiB
with 2 CPUs has two complete runs. Other workers held the two VM slots this host
allows for much of the time, and the host's load then made a further run
unusable. The runs still owed are listed under [Remaining runs](#remaining-runs).

What the runs so far show, each with the limits named:

- **Nothing failed.** Every scenario passed at every size measured, down to
  2048 MiB and 2 CPUs.
- **2048 MiB looks too small.** In its one run the guest build took 7m 23s and
  the driver scenarios 237 s, against 1m 19s and 55 s at 4096 MiB. The guest
  paged out at that size (peak 361 pages/s) and at no other. One run does not
  separate this from the host's state at the time.
- **3072 MiB looks slower than 4096 MiB:** builds of 1m 44s and 1m 33s and driver
  scenarios of 87 s and 65 s, in two runs, against one run at 4096 MiB.
- **4 CPUs show no gain so far.** At 4096 MiB the build took 1m 15s against
  1m 19s, and the NTFS matrix took longer (230 s against 141 s), from one run.
- **Timing here is noisy.** A repeat at 4096 MiB and 2 CPUs was stopped during
  its guest build with the host's load average above 500. Its NTFS matrix had
  passed in 694 s, against 141 s in the first run. It is not in the table, and
  its scenarios are not in `results.json`.

Peak guest memory was 1403 to 2272 MiB. It rises with the memory given, because
Windows keeps file cache while it can, so the peak alone does not set a size.

## How it was measured

`tests/vm-size-live.py` boots a new instance of the provisioned base at each
size with `instance --memory-mib --cpus`, so the base is never changed. Its
disk's hash was unchanged after the last run. Every boot starts from the same
reset point. Each boot runs, in order:

1. rust-fs-ntfs at `ae8283d6`, filter `mac-format-tiny-32mib`: this ships the
   consumer's scripts.
2. rust-fs-ntfs, group `smoke`, 5 scenarios at `max_parallel = 4`, each with
   chkdsk validation through a VHD. `rust-img-vhd` v0.6.1, built once in
   a guest, is copied into each boot.
3. xfs-win-driver at `34bb40e`, filter `win-mount`, 4 scenarios mounting through
   WinFsp with the images from its CI. The guest's `target` directory is deleted
   first, so each run includes a cold `cargo build --release --features mount`
   in the guest.

Guest memory comes from `Win32_PerfFormattedData_PerfOS_Memory`, sampled every
2 seconds over SSH: peak used is total minus the lowest `AvailableMBytes`, and
peak commit is the highest `CommittedBytes`. The sampler is a PowerShell process
in the guest, and its own memory is included. The 4 GiB and 16 GiB rust-fs-ntfs
volumes were not run.

The host is an Apple Silicon Mac with 64 GiB and 10 CPUs. **All but one run
started beside another worker's 4 GiB VM,** on a host with little free memory, so
these are not controlled timings. `vm_stat` is summarized below and held in full
form in [results.json](results.json), as is each scenario's time.

## Results

Times are seconds except the guest build. "VMs" is how many other VMs ran at the
start and at the end. "Host" is free GiB and GiB held by the compressor, at the
start.

| MiB | CPUs | Round | Passed | NTFS smoke s | Peak used MiB | Peak commit MiB | Guest build | WinFsp scenarios s | Peak used MiB | Peak commit MiB | Peak pages out/s | VMs | Host |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| 2048 | 2 | 1 | 10/10 | 169 | 1403 | 1817 | 7m 23s | 237 | 1380 | 2031 | 361 | 1, 2 | 1.3, 23.9 |
| 3072 | 2 | 1 | 10/10 | 161 | 1779 | 1799 | 1m 44s | 87 | 1884 | 2056 | 0 | 1, 1 | 0.06, 28.94 |
| 3072 | 2 | 2 | 10/10 | 155 | 1812 | 1813 | 1m 33s | 65 | 1771 | 1886 | 0 | 0, 0 | 0.06, 30.64 |
| 4096 | 2 | 1 | 10/10 | 141 | 1943 | 1883 | 1m 19s | 55 | 1972 | 1945 | 0 | 1, 1 | 0.07, 24.65 |
| 4096 | 4 | 1 | 10/10 | 230 | 2013 | 1914 | 1m 15s | 60 | 2272 | 2380 | 0 | 1, 1 | 3.32, 29.6 |

## Remaining runs

- 2048 MiB, 2 CPUs, round 2
- 2048 MiB, 4 CPUs, round 1
- 2048 MiB, 4 CPUs, round 2
- 3072 MiB, 4 CPUs, round 1
- 3072 MiB, 4 CPUs, round 2
- 4096 MiB, 2 CPUs, round 2
- 4096 MiB, 4 CPUs, round 2

From a checkout of this tree, with the two consumers beside a harness checkout,
each with a `.test-env` naming `VM_HOST=fswth-local`, an empty `SSH_KEY` and its
own `VM_WORKDIR`, and `XFS_PREBUILT_IMAGES` pointing at xfs-win-driver's
`xfs-matrix-images` artifact:

```sh
RUSTUP_TOOLCHAIN=1.95.0 python3 -u -B tests/vm-size-live.py \
  --state-root "$HOME/tmp/constellation-loop/win-65/states" \
  --guest-tool rust-img-vhd.exe \
  --workload "$NTFS:mac-format-tiny-32mib" --workload "$NTFS:smoke" \
  --workload "$XFS:win-mount:C:/fswth/xfs-win-driver/target" \
  --size 2048:2 --size 2048:4 --size 3072:2 --size 3072:4 --size 4096:2 --size 4096:4 \
  --rounds 2 --slot-wait 3600 --output results.json
```

Given an existing `results.json`, it skips the size and round pairs already
there. `smoke` is run after the shipping filter because a group filter skips the
ship phase ([#70](https://github.com/antimatter-studios/fs-windows-test-harness/issues/70)).
