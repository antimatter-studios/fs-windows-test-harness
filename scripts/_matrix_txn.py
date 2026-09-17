"""_matrix_txn.py -- serialised read-modify-write of test-matrix.json.

Backs claim-scenario.sh, update-scenario-status.sh and
reset-non-passed.sh. Every mutation of the matrix goes through
`transaction()`, which holds an exclusive flock(2) for the whole
read -> modify -> atomic-replace sequence.

Why a lock and not "write atomically, then read back and check": an
atomic rename only makes each *write* whole. It does nothing about two
writers that both read the same old state. Claimer A reads, claimer B
reads the same bytes, A renames "sc00 claimed by A", B renames "sc00
claimed by B" over it, and a third claimer that had already read A's
file and claimed sc01 is silently undone by B's stale copy. The
read-back check could not see that either: it ran after the rename,
outside any critical section, so it raced the next writer in exactly
the same way. Serialising the whole transaction is the only fix; the
old retry loop merely made the window smaller.

Locking a file we then replace needs one extra step. The lock lives
on the inode we opened; after a writer renames a new file into place,
a waiter that was blocked on the old inode wakes up holding a lock on
a file nobody reads any more. So after acquiring the lock we check the
path still names the inode we locked, and start over if it does not.

Usage (from the shell scripts; not a public interface):
    python3 _matrix_txn.py claim  <matrix> <session>
    python3 _matrix_txn.py status <matrix> <scenario> <status> [<evidence>]
    python3 _matrix_txn.py reset  <matrix>
"""

import contextlib
import fcntl
import json
import os
import sys
import tempfile


@contextlib.contextmanager
def transaction(path):
    """Yield the parsed matrix under an exclusive lock.

    The body mutates the dict in place. On normal exit the result is
    written to a temp file beside `path` and renamed over it while the
    lock is still held, so no reader ever sees a partial file and no
    writer ever starts from a state another writer has replaced.
    """
    while True:
        fd = os.open(path, os.O_RDONLY)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            locked = os.fstat(fd)
            current = os.stat(path)
        except FileNotFoundError:
            os.close(fd)
            continue
        except BaseException:
            os.close(fd)
            raise
        if (locked.st_dev, locked.st_ino) == (current.st_dev, current.st_ino):
            break
        # Replaced while we waited: our lock guards a dead inode.
        os.close(fd)

    try:
        with os.fdopen(os.dup(fd), "r", encoding="utf-8") as f:
            data = json.load(f)
        yield data
        directory = os.path.dirname(os.path.abspath(path))
        tmp_fd, tmp_path = tempfile.mkstemp(
            prefix=os.path.basename(path) + ".tmp.", dir=directory
        )
        try:
            with os.fdopen(tmp_fd, "w", encoding="utf-8") as out:
                json.dump(data, out, indent=2, ensure_ascii=False)
                out.write("\n")
            # mkstemp creates 0600; keep the matrix's own permissions.
            os.chmod(tmp_path, locked.st_mode & 0o7777)
            os.replace(tmp_path, path)
        except BaseException:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(tmp_path)
            raise
    finally:
        # Closing the last descriptor on the inode releases the lock --
        # only after the replacement is in place.
        os.close(fd)


class NothingToDo(Exception):
    """Raised inside a transaction to abandon it without writing."""


def claim(path, session):
    try:
        with transaction(path) as data:
            for name, entry in data.get("scenarios", {}).items():
                if entry.get("status") == "pending":
                    entry["status"] = f"claimed-{session}"
                    picked = name
                    break
            else:
                raise NothingToDo
    except NothingToDo:
        return 1
    print(picked)
    return 0


def set_status(path, scenario, status, evidence=""):
    try:
        with transaction(path) as data:
            scenarios = data.get("scenarios", {})
            if scenario not in scenarios:
                raise NothingToDo
            scenarios[scenario]["status"] = status
            if evidence:
                scenarios[scenario]["evidence_link"] = evidence
    except NothingToDo:
        print(f"unknown scenario: {scenario}", file=sys.stderr)
        return 2
    print(f"{scenario} -> {status}")
    return 0


def reset(path):
    with transaction(path) as data:
        scenarios = data.get("scenarios", {})
        moved = 0
        for entry in scenarios.values():
            if not entry.get("status", "").startswith("passed-"):
                entry["status"] = "pending"
                moved += 1
    print(
        f"reset {moved} scenarios to pending; "
        f"{len(scenarios) - moved} remain passed-*"
    )
    return 0


def main(argv):
    commands = {
        "claim": (claim, 2, 2),
        "status": (set_status, 3, 4),
        "reset": (reset, 1, 1),
    }
    if len(argv) < 2 or argv[1] not in commands:
        print(f"usage: {argv[0]} claim|status|reset <matrix> ...", file=sys.stderr)
        return 2
    fn, lo, hi = commands[argv[1]]
    args = argv[2:]
    if not lo <= len(args) <= hi:
        print(f"{argv[1]}: wrong number of arguments", file=sys.stderr)
        return 2
    return fn(*args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
