#!/usr/bin/env python3
"""Opt-in: two real consumer matrices at once in one guest, each in its own workdir.

Each consumer is a separate checkout beside the harness checkout it names, with
a .test-env holding its own VM_WORKDIR, HARNESS_DIR and HOST_IMAGE_DIR. Prints
whether the runs overlapped, what each reported and how long each took. Compare
the walls with the same matrix run alone at the same size (tests/vm-size-live.py).
"""

import argparse
import datetime
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


def clock_window(log):
    """The first scenario start and last scenario end the runner's log shows."""
    text = log.read_text(errors="replace")
    starts = re.findall(r"^\[(\d\d:\d\d:\d\d)\]\[[^\]]*\] >>> ", text, re.MULTILINE)
    ends = re.findall(r"^\[(\d\d:\d\d:\d\d)\]\[[^\]]*\] (?:pass|fail) ", text, re.MULTILINE)
    if not starts or not ends:
        return None
    day = datetime.date.today().isoformat()
    return [
        datetime.datetime.fromisoformat(f"{day}T{min(starts)}"),
        datetime.datetime.fromisoformat(f"{day}T{max(ends)}"),
    ]


def pass_of(consumers, filter_name, environment, logs, label):
    runs = []
    beginning = time.monotonic()
    for consumer in consumers:
        log = logs / f"{label}-{consumer.name}.log"
        (consumer / "test-diagnostics/matrix/results.json").unlink(missing_ok=True)
        with log.open("wb") as sink:
            process = subprocess.Popen(
                ["bash", consumer.parent / "fs-windows-test-harness/scripts/run-tests.sh", filter_name],
                cwd=consumer, env=environment, stdout=sink, stderr=subprocess.STDOUT,
            )
        runs.append((process, consumer, log))
    records, windows = [], []
    for process, consumer, log in runs:
        status = process.wait(timeout=3600)
        results = consumer / "test-diagnostics/matrix/results.json"
        scenarios = json.loads(results.read_text()) if results.exists() else []
        window = clock_window(log)
        if window:
            windows.append(window)
        records.append({
            "consumer": consumer.name, "exit": status,
            "seconds_from_start": round(time.monotonic() - beginning, 1),
            "scenario_window": [item.isoformat() for item in window] if window else None,
            "scenarios": [
                {"name": item["name"], "status": item["status"],
                 "seconds": round(item["duration_secs"], 1), "error": (item["error"] or "")[:400]}
                for item in scenarios
            ],
        })
    outcome = {"runs": records, "wall_seconds": round(time.monotonic() - beginning, 1)}
    if len(windows) == 2:
        outcome["overlap_seconds"] = (
            min(window[1] for window in windows) - max(window[0] for window in windows)
        ).total_seconds()
    return outcome


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, default=vm.DEFAULT_STATE)
    parser.add_argument("--state", type=Path, required=True, help="a new instance's state directory")
    parser.add_argument("--port", type=int, default=22390)
    parser.add_argument("--memory-mib", type=int, required=True)
    parser.add_argument("--cpus", type=int, required=True)
    parser.add_argument("--consumer", type=Path, action="append", required=True)
    parser.add_argument("--filter", required=True, help="a scenario filter; a group name skips the ship phase (#70)")
    parser.add_argument("--guest-tool", action="append", default=[],
                        help="a host file copied to this boot's ~/.cargo/bin; the base is not changed")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    state = args.state.expanduser().resolve()
    vm.main([
        "--state", str(state), "instance", "--base", str(args.base.expanduser().resolve()),
        "--ssh-port", str(args.port), "--cpus", str(args.cpus), "--memory-mib", str(args.memory_mib),
    ])
    config = vm.load_config(state)
    report = {"memory_mib": args.memory_mib, "cpus": args.cpus, "filter": args.filter}
    with vm.exclusive(state):
        vm.up(state, config)
    try:
        vm.wait_ready(state, 600)
        environment = dict(os.environ, PATH=str(state / "bin") + os.pathsep + os.environ["PATH"])
        environment.setdefault("RUSTUP_TOOLCHAIN", "1.95.0")
        for tool in args.guest_tool:
            vm.run([state / "bin/scp", tool, f"fswth-local:.cargo/bin/{Path(tool).name}"],
                   capture_output=True, timeout=120)
        consumers = [consumer.expanduser().resolve() for consumer in args.consumer]
        # The first consumer alone, as the wall the pair is compared with.
        report["alone"] = pass_of(consumers[:1], args.filter, environment, args.output.parent, "alone")
        report["pair"] = pass_of(consumers, args.filter, environment, args.output.parent, "pair")
        report["attached_disk_images_after"] = vm.ssh(
            state, "@(Get-Disk | Where-Object { $_.Number -ne 0 -and $_.Size -gt 0 }).Count",
            capture_output=True, timeout=60,
        ).stdout.decode().strip()
    finally:
        with vm.exclusive(state):
            vm.down(state, 300, config)
        vm.write_json(args.output, report)
    print(json.dumps(report, indent=1))


if __name__ == "__main__":
    os.umask(0o077)
    main()
