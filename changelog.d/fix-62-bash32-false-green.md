### Fixed

- **A matrix run from macOS bash 3.2 no longer reports success having run nothing (#62).** `run-tests.sh` no longer needs `BASHPID`, and a run that dies before its end now fails, because bash 3.2 reports `$?=0` to an EXIT trap after `set -u` kills the script.
