#!/usr/bin/env python3
"""Opt-in sweep of guest sizes over a real consumer matrix; needs a provisioned base.

Every run boots a new instance of the base at one size, samples the guest's
memory over SSH while the consumer's matrix runs, and records what the matrix
reported, how long it took, and vm_stat and any other VMs on the host. Rounds
visit every size before repeating one, so a change on the host over time lands
on all sizes rather than on the last one measured.
"""

import argparse
import base64
import importlib.util
import json
import os
import re
import subprocess
import time
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "local_vm", Path(__file__).resolve().parents[1] / "scripts/local-vm.py"
)
vm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vm)

SAMPLER = r"""
$ProgressPreference = 'SilentlyContinue'
$total = (Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize
$cpus = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
"total_kib=$total cpus=$cpus"
while ($true) {
    $m = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
    $c = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
    "$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) $($m.AvailableMBytes) $($m.CommittedBytes) $($m.PagesInputPersec) $($m.PagesOutputPersec) $($c.PercentProcessorTime)"
    [Console]::Out.Flush()
    Start-Sleep -Seconds 2
}
"""


def other_vms():
    processes = subprocess.run(["pgrep", "-fl", "qemu-system-"], capture_output=True, text=True)
    if processes.returncode not in (0, 1):
        raise RuntimeError(f"Cannot count host VMs: {processes.stderr}")
    found = []
    for line in processes.stdout.splitlines():
        if not re.match(r"\d+ /opt/homebrew/bin/qemu-system-", line):
            continue
        memory = re.search(r" -m (\S+)", line)
        found.append({"pid": int(line.split()[0]), "memory": memory.group(1) if memory else None})
    return found


def host_memory():
    text = subprocess.run(["vm_stat"], check=True, capture_output=True, text=True).stdout
    page = int(re.search(r"page size of (\d+) bytes", text).group(1))
    pages = {name: int(count) for name, count in re.findall(r"^(?:Pages )?([^:\n]+):\s+(\d+)\.", text, re.MULTILINE)}
    gib = 1024 ** 3
    return {
        "free_gib": round(pages["free"] * page / gib, 2),
        "inactive_gib": round(pages["inactive"] * page / gib, 2),
        "compressor_gib": round(pages["occupied by compressor"] * page / gib, 2),
        "pageouts": pages["Pageouts"],
        "swapouts": pages["Swapouts"],
    }


def summarize(path, begin=None, end=None):
    lines = path.read_text(errors="replace").splitlines()
    head = next((re.match(r"total_kib=(\d+) cpus=(\d+)", line) for line in lines if line.startswith("total_kib")), None)
    if head is None:
        raise RuntimeError(f"The sampler reported no guest size: {path}")
    total_mib = int(head.group(1)) // 1024
    rows = [
        [int(field) for field in line.split()]
        for line in lines
        if re.fullmatch(r"\d+ \d+ \d+ \d+ \d+ \d+", line)
    ]
    if begin is not None:
        rows = [row for row in rows if begin <= row[0] <= end]
    if not rows:
        raise RuntimeError(f"The sampler reported no samples: {path}")
    return {
        "samples": len(rows),
        "guest_total_mib": total_mib,
        "guest_cpus": int(head.group(2)),
        "peak_used_mib": total_mib - min(row[1] for row in rows),
        "min_available_mib": min(row[1] for row in rows),
        "peak_commit_mib": max(row[2] for row in rows) // 1024 ** 2,
        "pages_in_per_sec_peak": max(row[3] for row in rows),
        "pages_in_per_sec_mean": round(sum(row[3] for row in rows) / len(rows), 1),
        "pages_out_per_sec_peak": max(row[4] for row in rows),
        "cpu_percent_mean": round(sum(row[5] for row in rows) / len(rows), 1),
    }


def remove_state(state):
    """Removes only the files a stopped instance is known to leave, by name."""
    names = [
        "ssh-key", "ssh_config", "known_hosts", "vm.json", "operation.lock",
        "qemu.log", "serial.log", "bin/ssh", "bin/scp", vm.RUN_DISK, vm.RUN_VARS,
    ]
    for name in names:
        (state / name).unlink(missing_ok=True)
    (state / "bin").rmdir()
    state.rmdir()


def matrix(state, workload, output, timeout):
    consumer = workload["consumer"]
    results = consumer / "test-diagnostics/matrix/results.json"
    results.unlink(missing_ok=True)
    env = dict(os.environ, VM_HOST="fswth-local", RUSTUP_TOOLCHAIN=os.environ.get("RUSTUP_TOOLCHAIN", "1.95.0"))
    if workload["clean"]:
        vm.ssh(state, f"Remove-Item -LiteralPath '{workload['clean']}' -Recurse -Force -ErrorAction SilentlyContinue",
               capture_output=True, timeout=300)
    begun = time.monotonic()
    epoch = int(time.time())
    with output.open("wb") as log:
        process = subprocess.run(
            [
                vm.sys.executable, Path(vm.__file__), "--state", state, "exec", "--",
                "bash", "scripts/run-matrix.sh", workload["filter"],
            ],
            cwd=consumer, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=timeout,
        )
    wall = time.monotonic() - begun
    text = output.read_text(errors="replace")
    finished = re.findall(r"finished in ([0-9.]+)s", text)
    built = re.findall(r"Finished `release` profile \[optimized\] target\(s\) in ([^\r\n]+)", text)
    scenarios = json.loads(results.read_text()) if results.exists() else []
    return {
        "consumer": consumer.name,
        "filter": workload["filter"],
        "exit": process.returncode,
        "wall_seconds": round(wall, 1),
        "runner_seconds": float(finished[-1]) if finished else None,
        "cargo_finished": built,
        "epoch": [epoch, int(time.time())],
        "scenarios": [
            {
                "name": item["name"], "status": item["status"],
                "seconds": round(item["duration_secs"], 1),
                "error": (item["error"] or "")[:300],
            }
            for item in scenarios
        ],
    }


def one_run(args, memory, cpus, round_number, port, outdir):
    label = f"m{memory}-c{cpus}-r{round_number}"
    state = args.state_root / label
    waited = time.monotonic()
    while len(other_vms()) >= args.slots and time.monotonic() - waited < args.slot_wait:
        time.sleep(10)
    record = {
        "waited_for_slot_seconds": round(time.monotonic() - waited),
        "memory_mib": memory, "cpus": cpus, "round": round_number,
        "other_vms_before": other_vms(), "host_before": host_memory(),
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    if len(record["other_vms_before"]) >= args.slots:
        raise RuntimeError(f"No free VM slot: {record['other_vms_before']}")
    vm.main([
        "--state", str(state), "instance", "--base", str(args.base),
        "--ssh-port", str(port), "--cpus", str(cpus), "--memory-mib", str(memory),
    ])
    config = vm.load_config(state)
    sampler = None
    try:
        begun = time.monotonic()
        with vm.exclusive(state):
            vm.up(state, config)
        vm.wait_ready(state, 600)
        record["boot_seconds"] = round(time.monotonic() - begun, 1)
        record["guest_tools"] = vm.ssh(
            state,
            "foreach ($n in 'cargo','rustc','rust-img-vhd','git','clang') "
            "{ $c = Get-Command $n -ErrorAction SilentlyContinue; \"$n=$(if ($c) { $c.Source })\" }",
            capture_output=True, timeout=120,
        ).stdout.decode(errors="replace").split()
        for tool in args.guest_tool:
            vm.run([state / "bin/scp", tool, f"fswth-local:.cargo/bin/{Path(tool).name}"],
                   capture_output=True, timeout=120)
        encoded = base64.b64encode(SAMPLER.encode("utf-16-le")).decode()
        samples = outdir / f"{label}.samples.txt"
        with samples.open("wb") as sink:
            sampler = subprocess.Popen(
                [state / "bin/ssh", "-n", "fswth-local", "powershell.exe", "-NoProfile",
                 "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded],
                stdout=sink, stderr=subprocess.DEVNULL,
            )
        record["matrix"] = []
        for index, workload in enumerate(args.workload):
            name = f"{label}.{index}-{workload['consumer'].name}"
            record["matrix"].append(matrix(state, workload, outdir / f"{name}.log", args.run_timeout))
            results = workload["consumer"] / "test-diagnostics/matrix/results.json"
            if results.exists():
                (outdir / f"{name}.results.json").write_bytes(results.read_bytes())
        record["host_during"] = host_memory()
        record["other_vms_after"] = other_vms()
        sampler.terminate()
        sampler.wait(timeout=30)
        sampler = None
        record["guest"] = summarize(samples)
        for item in record["matrix"]:
            item["guest"] = summarize(samples, *item["epoch"])
    except Exception as error:
        record["error"] = str(error)
    finally:
        if sampler is not None:
            sampler.terminate()
            sampler.wait(timeout=30)
        try:
            with vm.exclusive(state):
                vm.down(state, 300, config)
        except Exception as error:
            record["shutdown_error"] = str(error)
        record["host_after"] = host_memory()
    if "shutdown_error" not in record:
        remove_state(state)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, default=vm.DEFAULT_STATE)
    parser.add_argument("--state-root", type=Path, required=True)
    parser.add_argument("--workload", action="append", required=True,
                        help="CONSUMER_DIR:FILTER[:GUEST_DIR_TO_DELETE_FIRST]; repeatable, run in order")
    parser.add_argument("--size", action="append", required=True, help="MEMORY_MIB:CPUS; repeatable")
    parser.add_argument("--rounds", type=int, default=2)
    parser.add_argument("--first-round", type=int, default=1)
    parser.add_argument("--port", type=int, default=22370)
    parser.add_argument("--slots", type=int, default=2, help="VMs this host may run at once")
    parser.add_argument("--guest-tool", action="append", default=[],
                        help="a host file copied to this boot's ~/.cargo/bin; the base is not changed")
    parser.add_argument("--slot-wait", type=int, default=0, help="seconds to wait for a free VM slot")
    parser.add_argument("--run-timeout", type=int, default=3600)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.base = args.base.expanduser().resolve()
    args.state_root = args.state_root.expanduser().resolve()
    args.workload = [
        dict(zip(("consumer", "filter", "clean"), (*item.split(":", 2), None)))
        for item in args.workload
    ]
    for workload in args.workload:
        workload["consumer"] = Path(workload["consumer"]).expanduser().resolve()
    vm.private_dir(args.state_root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    before = {name: vm.sha256(args.base / name) for name in (vm.BASE_DISK, vm.BASE_VARS, "vm.json")}
    records = json.loads(args.output.read_text()) if args.output.exists() else []
    for round_number in range(args.first_round, args.first_round + args.rounds):
        for size in args.size:
            memory, cpus = (int(part) for part in size.split(":"))
            if any(r["memory_mib"] == memory and r["cpus"] == cpus and r["round"] == round_number for r in records):
                continue
            record = one_run(args, memory, cpus, round_number, args.port, args.output.parent)
            records.append(record)
            vm.write_json(args.output, records)
            print(json.dumps({key: record.get(key) for key in (
                "memory_mib", "cpus", "round", "boot_seconds", "error", "guest", "guest_tools", "other_vms_before"
            )}), flush=True)
            for item in record.get("matrix", []):
                passed = sum(s["status"] == "passed" for s in item["scenarios"])
                print(f"  {item['consumer']} {item['filter']}: exit {item['exit']} {passed}/{len(item['scenarios'])} "
                      f"wall {item['wall_seconds']} runner {item['runner_seconds']} "
                      f"built {item['cargo_finished']} peak {item.get('guest', {}).get('peak_used_mib')}", flush=True)
    after = {name: vm.sha256(args.base / name) for name in before}
    if before != after:
        raise RuntimeError(f"The base changed: {before} -> {after}")
    print(f"Base unchanged; {len(records)} runs in {args.output}")


if __name__ == "__main__":
    os.umask(0o077)
    main()
