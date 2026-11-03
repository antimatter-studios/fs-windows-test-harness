### Added
- `local-vm.py --state <instance> instance --base <provisioned-state> --ssh-port <port>` creates independent Windows VM instances backed by one read-only base disk, without copying or rebuilding it. Each instance has its own boot overlay, UEFI variables, SSH transport, runtime sockets and operation lock; existing single-VM commands and state directories are unchanged.
- An opt-in real-Windows sharing proof records backing-disk immutability, per-instance disk usage, boot time, host memory, concurrent harness runs and drive-letter and mountpoint collisions.
