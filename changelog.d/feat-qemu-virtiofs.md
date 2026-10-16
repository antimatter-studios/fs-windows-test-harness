### Added

- Optional virtio-fs image sharing, its guest driver setup, and fenced ship steps that copy through a configured shared directory.

### Changed

- Linux QEMU startup checks its inherited memory policy, requests local allocation for interleaving, and reports the effective result.
