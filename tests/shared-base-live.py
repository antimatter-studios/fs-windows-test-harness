#!/usr/bin/env python3
"""Opt-in real Windows proof; requires existing QEMU, a provisioned base and free VM slots."""

import argparse
import datetime
import importlib.util
import json
import os
import re
import subprocess
import time
import uuid
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "local_vm", Path(__file__).resolve().parents[1] / "scripts/local-vm.py"
)
vm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vm)


def memory():
    result = subprocess.run(["vm_stat"], check=True, capture_output=True, text=True).stdout
    page_size = int(re.search(r"page size of (\d+) bytes", result).group(1))
    pages = {
        name: int(count)
        for name, count in re.findall(r"^(Pages [^:]+):\s+(\d+)\.", result, re.MULTILINE)
    }
    return {"vm_stat": result, "free_bytes": pages["Pages free"] * page_size}


def fingerprint(base):
    return {
        name: vm.sha256(base / name)
        for name in (vm.BASE_DISK, vm.BASE_VARS, "uefi-code.fd", "ssh-key", "vm.json")
    }


def footprint(state):
    return {
        str(file.relative_to(state)): file.stat().st_blocks * 512
        for file in state.rglob("*")
        if file.is_file()
    }


def slots_needed(count):
    processes = subprocess.run(
        ["pgrep", "-fl", "qemu-system-"], capture_output=True, text=True
    )
    if processes.returncode not in (0, 1):
        raise RuntimeError(f"Cannot count host VMs: {processes.stderr}")
    existing = [
        line for line in processes.stdout.splitlines()
        if re.match(r"\d+ /opt/homebrew/bin/qemu-system-", line)
    ]
    if len(existing) + count > 2:
        raise RuntimeError(f"Need {count} free VM slots; already running: {existing}")
    return existing


def harness_status(consumer):
    """What the runner reported: it writes results.json, never test-matrix.json."""
    results = consumer / "test-diagnostics/matrix/results.json"
    if not results.exists():
        return None
    return next(
        (item["status"] for item in json.loads(results.read_text()) if item["name"] == "shared-vm-probe"),
        None,
    )


def start_run(state, root, remote, label, peer, drive, mode="pass"):
    """Starts one real harness run in its own workdir, returning (process, consumer, workdir)."""
    harness = Path(__file__).resolve().parents[1]
    consumer = root / f"consumer-{label}"
    vm.private_dir(consumer)
    workdir = f"{remote}/{label}"
    (consumer / "fs-windows-test-harness.toml").write_text(
        '[project]\nname = "shared-vm-proof"\nbinary = "unused"\n'
        'matrix_path = "test-matrix.json"\n'
        '[vm]\nhost = "${VM_HOST}"\nssh_key = "${SSH_KEY}"\n'
        'workdir = "${VM_WORKDIR}"\nimage_dir = "images"\n'
        '[runner]\nmax_parallel = 1\n'
        '[ops.probe]\nhost = "vm"\nexpect_exit = 0\n'
        f'''command = "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '{remote}/run.ps1' -Root '{{vm.workdir}}' -Peer '{remote}/{peer}' -Drive {drive} -Mode {mode}"\n'''
    )
    vm.write_json(consumer / "test-matrix.json", {
        "scenarios": {"shared-vm-probe": {
            "status": "pending", "image": "unused.img", "recipe": [{"op": "probe"}],
        }},
    })
    results = consumer / "test-diagnostics/matrix/results.json"
    results.unlink(missing_ok=True)
    with (consumer / "run.log").open("ab") as log:
        process = subprocess.Popen([
            "/bin/bash", harness / "scripts/run-tests.sh", "--no-ship",
            "--vm-host=fswth-local", f"--ssh-key={state / 'ssh-key'}",
            f"--vm-workdir={workdir}",
        ], env=dict(os.environ, CONSUMER_ROOT=str(consumer),
                    HARNESS_TOML=str(consumer / "fs-windows-test-harness.toml"),
                    PATH=str(state / "bin") + os.pathsep + os.environ["PATH"]),
            stdout=log, stderr=subprocess.STDOUT)
    return process, consumer, workdir


def stop_all(runs):
    for process, consumer, workdir in runs:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=30)


def guest_result(state, workdir):
    result = vm.ssh(state, f"Get-Content -Raw '{workdir}/result.json'", capture_output=True, timeout=60)
    return json.loads(result.stdout)


def overlap_seconds(pair):
    latest_start = max(datetime.datetime.fromisoformat(item["start_utc"]) for item in pair)
    earliest_end = min(datetime.datetime.fromisoformat(item["end_utc"]) for item in pair)
    return (earliest_end - latest_start).total_seconds()


def concurrent_runs(state, root, remote):
    vm.run([
        state / "bin/scp", Path(__file__).with_name("shared-vm-run.ps1"),
        f"fswth-local:{remote}/run.ps1",
    ], capture_output=True, timeout=60)
    records = []
    for round_number in range(1, 4):
        beginning = time.monotonic()
        runs = []
        try:
            for name, peer, drive in (("a", "b", "X"), ("b", "a", "Y")):
                runs.append(start_run(
                    state, root, remote, f"{round_number}-{name}", f"{round_number}-{peer}", drive,
                ))
            for process, consumer, workdir in runs:
                if process.wait(timeout=300) != 0:
                    raise RuntimeError(f"Concurrent run failed: {consumer / 'run.log'}")
            pair = []
            for process, consumer, workdir in runs:
                pair.append(guest_result(state, workdir))
                status = harness_status(consumer)
                if status != "passed":
                    raise AssertionError(f"Harness did not report passed: {status} in {consumer}")
            overlap = overlap_seconds(pair)
            if overlap <= 0:
                raise AssertionError("The two real harness runs did not overlap")
            records.append({"round": round_number, "elapsed_seconds": time.monotonic() - beginning,
                            "overlap_seconds": overlap, "runs": pair})
        finally:
            stop_all(runs)
    return records


def guest_probe(state, drive, workdir):
    """Whether the drive is still mounted, and by the process the crashed run left."""
    command = (
        f"$pidFile = '{workdir}/memfs.pid'; $orphan = $null; "
        "if (Test-Path -LiteralPath $pidFile) { "
        "$orphan = Get-Process -Id ([int](Get-Content -LiteralPath $pidFile)) -ErrorAction SilentlyContinue }; "
        f"[ordered]@{{ drive_mounted = (Test-Path '{drive}:\\'); "
        "memfs_alive = ($null -ne $orphan); memfs_pid = $(if ($orphan) { $orphan.Id } else { $null }) } "
        "| ConvertTo-Json -Compress"
    )
    return json.loads(vm.ssh(state, command, capture_output=True, timeout=60).stdout)


def failure_isolation(state, root, remote):
    """One run of a pair fails, or dies abruptly, with both mounted."""
    records = []
    for mode in ("fail", "crash"):
        for round_number in (1, 2):
            first, second = f"{mode}-{round_number}-a", f"{mode}-{round_number}-b"
            runs = []
            try:
                runs.append(start_run(state, root, remote, first, second, "X", mode))
                runs.append(start_run(state, root, remote, second, first, "Y"))
                exits = [process.wait(timeout=300) for process, consumer, workdir in runs]
                failing, surviving = runs
                record = {
                    "mode": mode, "round": round_number,
                    "failing_exit": exits[0], "failing_status": harness_status(failing[1]),
                    "surviving_exit": exits[1], "surviving_status": harness_status(surviving[1]),
                    "surviving_result": guest_result(state, surviving[2]),
                    "after": guest_probe(state, "X", failing[2]),
                }
                if record["failing_status"] == "passed":
                    raise AssertionError(f"The failing run reported passed: {record}")
                if record["surviving_status"] != "passed" or exits[1] != 0:
                    raise AssertionError(f"One run's failure failed the other: {record}")
                if mode == "crash" and record["after"]["memfs_alive"]:
                    # The next run to ask for that letter, in the crashed run's own workdir.
                    process, consumer, workdir = start_run(
                        state, root, remote, first, second, "X",
                    )
                    runs.append((process, consumer, workdir))
                    record["next_run_exit"] = process.wait(timeout=300)
                    record["next_run_status"] = harness_status(consumer)
                    vm.ssh(state, f"Stop-Process -Id {record['after']['memfs_pid']} -Force", capture_output=True, timeout=60)
                    time.sleep(2)
                    process, consumer, workdir = start_run(
                        state, root, remote, first, second, "X",
                    )
                    runs.append((process, consumer, workdir))
                    record["run_after_cleanup_exit"] = process.wait(timeout=300)
                    record["run_after_cleanup_status"] = harness_status(consumer)
                    record["after_cleanup"] = guest_probe(state, "X", failing[2])
                records.append(record)
            finally:
                stop_all(runs)
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, default=vm.DEFAULT_STATE)
    parser.add_argument("--state-root", type=Path, required=True)
    parser.add_argument("--count", type=int, choices=(1, 2), default=2)
    parser.add_argument("--first-port", type=int, default=22364)
    parser.add_argument("--memory-mib", type=int, help="default: the base's")
    parser.add_argument("--cpus", type=int, help="default: the base's")
    args = parser.parse_args()
    base = args.base.expanduser().resolve()
    root = args.state_root.expanduser().resolve()
    vm.private_dir(root)
    report = {"base": str(base), "count": args.count, "other_vms": slots_needed(args.count)}
    report["before"] = fingerprint(base)
    report["memory_before"] = memory()
    report["instances"] = []
    started = []
    nonce = uuid.uuid4().hex
    try:
        for index in range(args.count):
            state = root / f"instance-{index + 1}"
            if (state / "vm.json").exists():
                raise RuntimeError(f"Use a fresh state root: {state}")
            vm.main([
                "--state", str(state), "instance", "--base", str(base),
                "--ssh-port", str(args.first_port + index),
                *(["--memory-mib", str(args.memory_mib)] if args.memory_mib else []),
                *(["--cpus", str(args.cpus)] if args.cpus else []),
            ])
            config = vm.load_config(state)
            slots_needed(1)
            beginning = time.monotonic()
            with vm.exclusive(state):
                vm.up(state, config)
            started.append((state, config))
            vm.wait_ready(state, 600)
            record = {
                "state": str(state), "boot_seconds": time.monotonic() - beginning,
                "pid": int((vm.runtime_dir(state) / "vm.pid").read_text()),
                "memory": memory(), "files_after_boot": footprint(state),
            }
            if (state / vm.BASE_DISK).exists():
                raise AssertionError("An instance copied the base disk")
            nodes = vm.qmp(state, "query-named-block-nodes")
            backing = [node for node in nodes if node.get("file") == str(base / vm.BASE_DISK)]
            if not backing or not all(node["ro"] for node in backing):
                raise AssertionError(f"Base is not read-only in QEMU: {nodes}")
            record["base_nodes"] = backing
            report["instances"].append(record)
        report["memory_simultaneous"] = memory()
        marker = f"C:/fswth/{nonce}.txt"
        for index, (state, config) in enumerate(started):
            vm.ssh(state, f"if (Test-Path '{marker}') {{ exit 1 }}; New-Item -ItemType Directory C:/fswth -Force | Out-Null; Set-Content '{marker}' 'instance-{index + 1}'", capture_output=True, timeout=60)
        for index, (state, config) in enumerate(started):
            result = vm.ssh(state, f"Get-Content '{marker}'", capture_output=True, timeout=60)
            if result.stdout.strip() != f"instance-{index + 1}".encode():
                raise AssertionError(f"Guest writes leaked between overlays: {result.stdout}")
            report["instances"][index]["files_after_writes"] = footprint(state)
        first, config = started[0]
        remote = f"C:/fswth/shared-base-{nonce}"
        vm.ssh(first, f"New-Item -ItemType Directory '{remote}' -Force | Out-Null", capture_output=True, timeout=60)
        vm.run([first / "bin/scp", Path(__file__).with_name("shared-vm-collisions.ps1"), f"fswth-local:{remote}/collisions.ps1"], capture_output=True, timeout=60)
        result = vm.ssh(first, f"& '{remote}/collisions.ps1' -Root '{remote}/runs'; if (-not $?) {{ exit 1 }}", capture_output=True, timeout=600)
        report["same_vm_mounts"] = json.loads(result.stdout)
        report["concurrent_harness_runs"] = concurrent_runs(first, root, remote)
        report["failure_isolation"] = failure_isolation(first, root, remote)
        report["memory_after_tests"] = memory()
        report["tests_passed"] = True
    finally:
        errors = []
        for state, config in reversed(started):
            try:
                report.setdefault("files_before_shutdown", {})[str(state)] = footprint(state)
                with vm.exclusive(state):
                    vm.down(state, 180, config)
            except Exception as error:
                errors.append(f"{state}: {error}")
        report["shutdown_errors"] = errors
        report["after"] = fingerprint(base)
        report["base_unchanged"] = report["before"] == report["after"]
        report["memory_after_shutdown"] = memory()
        report["passed"] = bool(report.get("tests_passed")) and not errors and report["base_unchanged"]
        vm.write_json(root / "measurement.json", report)
        if errors or not report["base_unchanged"]:
            raise RuntimeError(f"Shutdown errors {errors}; base unchanged: {report['base_unchanged']}")
    print(f"Real Windows proof passed; measurements: {root / 'measurement.json'}")


if __name__ == "__main__":
    os.umask(0o077)
    main()
