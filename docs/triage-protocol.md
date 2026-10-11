# Triage protocol

How to interpret a failed scenario. Order matters: each step narrows
the search space cheaply before the next, more expensive one.

## 1. The FAIL line

The run's transcript names every failed scenario on a `FAIL` line: the
step, its op and why it stopped, either `exit Some(1) != expected 0` or
`errored: <reason>`. The last 4 KB of that step's stderr and stdout follow
it. Often that is enough.

## 2. Top-level results

Open `test-diagnostics/matrix/results.json`, one entry per scenario:

```json
{
  "name": "ro-list-root",
  "status": "failed",
  "error": "step 1 (ls) exit Some(1) != expected 0\n--- stderr ---\n...",
  "diag_dir": "/path/to/consumer/test-diagnostics/matrix/ro-list-root",
  "duration_secs": 4.2
}
```

Statuses:

- `passed` — every step exited with its expected code.
- `failed` — a step exited with another code, or errored: its command
  could not be built (an unresolved template reference), could not start,
  or hit `FSWTH_STEP_TIMEOUT_SECONDS`. The recipe stopped there.
- `errored` — the runner could not run the recipe at all, for example
  because a step names an op that `[ops]` does not declare. Fix the
  configuration before suspecting the driver.

A scenario with no recipe is reported as ignored and has no entry here.

## 3. The recipe

`<diag-dir>/recipe.json` lists every step that ran, in order, and
`overall_passed`. Steps stop at the first failure, so the last entry is
the one to read.

## 4. The failing step

Each step has its own directory, `<diag-dir>/step-NN/`:

- **`step.json`** — what ran and how it ended:

  ```json
  {
    "index": 1, "op": "ls", "host": "vm",
    "command": "C:/fswth/my-driver/target/release/my-driver.exe ls ...",
    "exit_code": 1, "expected_exit": 0, "duration_ms": 2310,
    "skipped": false, "skip_reason": null, "error": null
  }
  ```

  `command` is the template after substitution, so a wrong token shows
  here. When `error` is set and `exit_code` is null, the step never
  produced an exit code; `error` says why.
- **`stdout.txt`** + **`stderr.txt`** — the step's full output. For a
  `host = "vm"` step that is everything the Windows side printed,
  including the harness's op scripts: a mount that exited early or never
  printed its ready line says so in `stderr.txt`.

`test-diagnostics/vm-lease-heartbeat.log` records the VM-workdir lease, for
a run that lost its lease or waited on another.

## 5. Reproducing by hand

Once you have a hypothesis, drop the test harness and reproduce by
hand:

1. Take `command` from the failing step's `step.json`.
2. Run it where the step ran: on the host for `host = "host"`, or in the
   guest for `host = "vm"` (on the QEMU guest, `python3
   scripts/local-vm.py ssh -- '<command>'` from the harness checkout).
3. Compare to your hypothesis.

This loop is *much* faster than re-running the full matrix harness for
hypothesis testing. Use the harness for regression confirmation; use
direct invocation for diagnosis.

## 6. Patching + recording the fix

After you fix the driver, update the scenario:

- Add an entry to `_attempts` in `test-matrix.json` describing the
  hypothesis, the change, and the result.
- Reset the scenario's status with
  `bash ../fs-windows-test-harness/scripts/update-scenario-status.sh <name> pending`.
- Re-run the harness to confirm.

If the scenario passes, record it with
`bash ../fs-windows-test-harness/scripts/update-scenario-status.sh <name> passed-<session> <diag-dir>`;
the third argument is written to `evidence_link`. The runner itself never
changes a scenario's status.

## Anti-patterns

- **Don't hand-edit a scenario's `expect_*` to make it pass.** That
  silently widens the contract. Either the driver is wrong (fix it) or
  the expectation was wrong (write down *why* it changed in `_notes`).
- **Don't skip past a failed mount to chase other failures.** A mount
  that failed can leave a drive letter or WinFsp host state behind for
  the scenarios after it.
- **Don't trust a green run after editing only `expect_*`.** Re-run
  with a clean diag dir.
