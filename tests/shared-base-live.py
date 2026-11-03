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


def concurrent_runs(state, root, remote):
    harness = Path(__file__).resolve().parents[1]
    vm.run([
        state / "bin/scp", Path(__file__).with_name("shared-vm-run.ps1"),
        f"fswth-local:{remote}/run.ps1",
    ], capture_output=True, timeout=60)
    records = []
    for round_number in range(1, 4):
        processes = []
        beginning = time.monotonic()
        for name, peer, drive in (("a", "b", "X"), ("b", "a", "Y")):
            consumer = root / f"consumer-{round_number}-{name}"
            vm.private_dir(consumer)
            workdir = f"{remote}/{round_number}-{name}"
            peer_dir = f"{remote}/{round_number}-{peer}"
            (consumer / "fs-windows-test-harness.toml").write_text(
                '[project]\nname = "shared-vm-proof"\nbinary = "unused"\n'
                'matrix_path = "test-matrix.json"\n'
                '[vm]\nhost = "${VM_HOST}"\nssh_key = "${SSH_KEY}"\n'
                'workdir = "${VM_WORKDIR}"\nimage_dir = "images"\n'
                '[runner]\nmax_parallel = 1\n'
                '[ops.probe]\nhost = "vm"\nexpect_exit = 0\n'
                f'''command = "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '{remote}/run.ps1' -Root '{{vm.workdir}}' -Peer '{peer_dir}' -Drive {drive}"\n'''
            )
            vm.write_json(consumer / "test-matrix.json", {
                "scenarios": {"shared-vm-probe": {
                    "status": "pending", "image": "unused.img", "recipe": [{"op": "probe"}],
                }},
            })
            log = (consumer / "run.log").open("wb")
            try:
                process = subprocess.Popen([
                    "/bin/bash", harness / "scripts/run-tests.sh", "--no-ship",
                    "--vm-host=fswth-local", f"--ssh-key={state / 'ssh-key'}",
                    f"--vm-workdir={workdir}",
                ], env=dict(os.environ, CONSUMER_ROOT=str(consumer),
                            HARNESS_TOML=str(consumer / "fs-windows-test-harness.toml"),
                            PATH=str(state / "bin") + os.pathsep + os.environ["PATH"]),
                    stdout=log, stderr=subprocess.STDOUT)
            except BaseException:
                for previous, previous_consumer, previous_workdir in processes:
                    if previous.poll() is None:
                        previous.terminate()
                        previous.wait(timeout=30)
                raise
            finally:
                log.close()
            processes.append((process, consumer, workdir))
        try:
            for process, consumer, workdir in processes:
                if process.wait(timeout=300) != 0:
                    raise RuntimeError(f"Concurrent run failed: {consumer / 'run.log'}")
            pair = []
            for process, consumer, workdir in processes:
                result = vm.ssh(state, f"Get-Content -Raw '{workdir}/result.json'", capture_output=True, timeout=60)
                pair.append(json.loads(result.stdout))
                matrix = json.loads((consumer / "test-matrix.json").read_text())
                if matrix["scenarios"]["shared-vm-probe"]["status"] != "passed":
                    raise AssertionError(f"Harness did not report passed: {matrix}")
            latest_start = max(datetime.datetime.fromisoformat(item["start_utc"]) for item in pair)
            earliest_end = min(datetime.datetime.fromisoformat(item["end_utc"]) for item in pair)
            overlap = (earliest_end - latest_start).total_seconds()
            if overlap <= 0:
                raise AssertionError("The two real harness runs did not overlap")
            records.append({"round": round_number, "elapsed_seconds": time.monotonic() - beginning,
                            "overlap_seconds": overlap, "runs": pair})
        finally:
            for process, consumer, workdir in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=30)
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, default=vm.DEFAULT_STATE)
    parser.add_argument("--state-root", type=Path, required=True)
    parser.add_argument("--count", type=int, choices=(1, 2), default=2)
    parser.add_argument("--first-port", type=int, default=22364)
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
