### Fixed

- **A `[groups]` filter gets the preflight, the matrix lock and the ship phase (#70).** `run-tests.sh <group>` matched the filter against scenario names only, so a group of VM scenarios ran with no lock and with whatever scripts the guest already held. It now selects the scenarios the runner will run, and a group of host-only scenarios still does not touch the VM.
