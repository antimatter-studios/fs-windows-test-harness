#!/usr/bin/env python3
"""Opt-in backing-image oracle; requires existing qemu-img and qemu-io, not a VM."""

import argparse
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "local_vm", Path(__file__).resolve().parents[1] / "scripts/local-vm.py"
)
vm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vm)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-root", type=Path, required=True)
    args = parser.parse_args()
    root = args.state_root.expanduser().resolve()
    if root.exists():
        raise RuntimeError("Choose a fresh scratch state root; existing files are never replaced")
    for name in ("qemu-img", "qemu-io", "ssh", "scp"):
        vm.tool(name)
    base = root / "base"
    vm.private_dir(base)
    vm.run(["qemu-img", "create", "-q", "-f", "qcow2", base / vm.BASE_DISK, "8M"], timeout=30)
    vm.run(["qemu-io", "-f", "qcow2", "-c", "write -P 0x42 0 512", base / vm.BASE_DISK], capture_output=True, timeout=30)
    vm.write_json(base / "vm.json", {
        "version": 1, "install_started": True, "provisioned": True,
        "ssh_port": 22260, "cpus": 2, "memory_mib": 4096,
    })
    for name in (vm.BASE_VARS, "uefi-code.fd", "ssh-key"):
        (base / name).write_bytes(b"image-oracle fixture, never booted")
    before = vm.sha256(base / vm.BASE_DISK)
    instances = []
    for index, pattern in enumerate(("0xa1", "0xb2")):
        state = root / f"instance-{index}"
        vm.main([
            "--state", str(state), "instance", "--base", str(base),
            "--ssh-port", str(22261 + index),
        ])
        vm.reset(state)
        instances.append((state, pattern))
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        futures = [executor.submit(vm.run, [
            "qemu-io", "-f", "qcow2", "-c", f"write -P {pattern} 0 512", state / vm.RUN_DISK,
        ], capture_output=True, timeout=30) for state, pattern in instances]
        for future in futures:
            future.result()
    for state, pattern in instances:
        vm.run(["qemu-io", "-f", "qcow2", "-c", f"read -P {pattern} 0 512", state / vm.RUN_DISK], capture_output=True, timeout=30)
        info = vm.run(["qemu-img", "info", "--output=json", state / vm.RUN_DISK], capture_output=True, timeout=30)
        if json.loads(info.stdout)["full-backing-filename"] != str(base / vm.BASE_DISK):
            raise AssertionError("Overlay does not reference the shared original")
        if (state / vm.BASE_DISK).exists():
            raise AssertionError("An instance copied the base")
    vm.run(["qemu-io", "-f", "qcow2", "-c", "read -P 0x42 0 512", base / vm.BASE_DISK], capture_output=True, timeout=30)
    after = vm.sha256(base / vm.BASE_DISK)
    if before != after:
        raise AssertionError("Writing an overlay changed the base")
    vm.write_json(root / "measurement.json", {"base_sha256": after, "overlays_verified": 2, "base_unchanged": True})
    print(f"Two real qcow2 overlays verified; base unchanged: {after}")


if __name__ == "__main__":
    os.umask(0o077)
    main()
