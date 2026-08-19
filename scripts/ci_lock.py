#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc

"""Host-wide mutex for `make ci`.

`scripts/run-ci.sh` owns two *global* resources for the whole of its run: the
fixed-path ephemeral test keychain (`ci-test.keychain-db`) and the user-domain
default keychain. Two concurrent runs on one host delete each other's keychain
at startup and stomp the shared default mid-test, and every resulting failure
reads as a flaky test rather than as contention. This wrapper serializes them.

Why an flock and not a PID file
-------------------------------
The kernel drops an flock when the holding process dies, however it dies:
`exit`, SIGKILL, a panic, a yanked SSH session. There is no stale lock to
detect, so there is no staleness heuristic to get wrong, and a crashed lane
cannot wedge the next one. A PID file only approximates that, and gets PID
reuse wrong.

Why exec and not a supervisor
-----------------------------
The lock fd is handed to the payload by `exec`, so the lock's lifetime is
exactly the payload's lifetime and the payload's own exit status is this
process's exit status — nothing is interposed between the caller and the
command it ran. A supervising parent has the inverse failure: kill the
supervisor and the lock is released while the payload keeps running.

The payload is responsible for closing the lock fd in *its* children (see
`run-ci.sh`, which appends `9>&-` to the test phase), so an orphaned test
process cannot keep the lock alive after the run it belonged to is gone.

Where the lock file lives
-------------------------
`~/.local/state/sol-pbc/` — per-user, matching the per-user scope of the
keychains being guarded, and not under any directory macOS periodically
purges. A purged-out-from-under-us lock file is the one failure this design
cannot survive: two runs would hold locks on different inodes and each would
believe it was alone. `~/Library/Caches` and `$TMPDIR` are both purgeable and
are deliberately not used.

Usage
-----
    ci_lock.py [--timeout S] [--lock PATH] -- <command> [args...]
    ci_lock.py --status [--lock PATH]

`--status` exits 0 when the lock is free and 75 when it is held, and prints
who holds it either way.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import pathlib
import socket
import sys
import time

# The payload inherits the lock on this fd. Fixed rather than dynamic so a
# shell payload can name it in a redirection (`9>&-`) to keep it out of its
# own children.
LOCK_FD = 9

LOCK_PATH_ENV = "SOLSTONE_CI_LOCK"
LOCK_FD_ENV = "SOLSTONE_CI_LOCK_FD"
TIMEOUT_ENV = "SOLSTONE_CI_LOCK_TIMEOUT"

DEFAULT_TIMEOUT_S = 3600.0
POLL_INTERVAL_S = 1.0
PROGRESS_INTERVAL_S = 60.0

EXIT_BUSY = 75  # EX_TEMPFAIL — the lock stayed held for the whole wait.
EXIT_USAGE = 64  # EX_USAGE
EXIT_NOCMD = 127  # payload not executable, matching shell convention


def default_lock_path() -> pathlib.Path:
    override = os.environ.get(LOCK_PATH_ENV)
    if override:
        return pathlib.Path(override)
    home = pathlib.Path(os.path.expanduser("~"))
    return home / ".local" / "state" / "sol-pbc" / "solstone-macos-ci.lock"


def default_timeout() -> float:
    raw = os.environ.get(TIMEOUT_ENV)
    if not raw:
        return DEFAULT_TIMEOUT_S
    try:
        value = float(raw)
    except ValueError:
        raise SystemExit(f"ci_lock: {TIMEOUT_ENV} is not a number: {raw!r}")
    if value < 0:
        raise SystemExit(f"ci_lock: {TIMEOUT_ENV} must not be negative: {raw!r}")
    return value


def holder_record(argv: list[str]) -> dict:
    return {
        "pid": os.getpid(),
        "host": socket.gethostname(),
        "started": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "cwd": os.getcwd(),
        "command": argv,
    }


def read_holder(path: pathlib.Path) -> dict | None:
    """Best-effort read of the holder record.

    Diagnostics only: a reader can catch a writer mid-write, so unparseable
    content means "holder unknown", never an error.
    """
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        return None
    try:
        record = json.loads(raw)
    except ValueError:
        return None
    return record if isinstance(record, dict) else None


def describe_holder(path: pathlib.Path) -> str:
    record = read_holder(path)
    if not record:
        return "holder unknown (no readable record in the lock file)"
    command = record.get("command")
    if isinstance(command, list):
        command = " ".join(str(part) for part in command)
    return (
        f"pid {record.get('pid', '?')} on {record.get('host', '?')} "
        f"since {record.get('started', '?')} — {command or '?'}"
    )


def write_holder(fd: int, argv: list[str]) -> None:
    """Stamp the lock file with who holds it, in a single write."""
    payload = json.dumps(holder_record(argv)).encode("utf-8") + b"\n"
    try:
        os.ftruncate(fd, 0)
        os.pwrite(fd, payload, 0)
    except OSError as exc:  # diagnostics must never fail the run
        print(f"ci_lock: warn: could not record holder: {exc}", file=sys.stderr)


def open_lock(path: pathlib.Path) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    return os.open(path, os.O_RDWR | os.O_CREAT, 0o644)


def acquire(
    fd: int,
    path: pathlib.Path,
    timeout_s: float,
    *,
    poll_interval_s: float = POLL_INTERVAL_S,
    progress_interval_s: float = PROGRESS_INTERVAL_S,
    clock=time.monotonic,
    sleep=time.sleep,
) -> bool:
    """Take the exclusive lock, or return False once `timeout_s` has passed."""
    deadline = clock() + timeout_s
    next_progress = clock() + progress_interval_s
    waited_from = clock()
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError:
            pass
        now = clock()
        if now >= deadline:
            return False
        if now >= next_progress:
            waited = int(now - waited_from)
            print(
                f"ci_lock: still waiting {waited}s for {path} — "
                f"held by {describe_holder(path)}",
                file=sys.stderr,
                flush=True,
            )
            next_progress = now + progress_interval_s
        sleep(min(poll_interval_s, max(0.0, deadline - now)))


def run_status(path: pathlib.Path) -> int:
    try:
        fd = open_lock(path)
    except OSError as exc:
        print(f"ci_lock: cannot open {path}: {exc}", file=sys.stderr)
        return EXIT_USAGE
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print(f"held: {path}\n  {describe_holder(path)}")
            return EXIT_BUSY
        fcntl.flock(fd, fcntl.LOCK_UN)
        print(f"free: {path}")
        return 0
    finally:
        os.close(fd)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="ci_lock.py",
        description="Serialize `make ci` runs on one host.",
    )
    parser.add_argument("--lock", default=None, help="lock file path")
    parser.add_argument(
        "--timeout",
        type=float,
        default=None,
        help=f"seconds to wait for the lock (default {DEFAULT_TIMEOUT_S:.0f}, "
        f"or ${TIMEOUT_ENV})",
    )
    parser.add_argument(
        "--status",
        action="store_true",
        help="report whether the lock is held; exit 0 free, 75 held",
    )
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)

    path = pathlib.Path(args.lock) if args.lock else default_lock_path()

    if args.status:
        return run_status(path)

    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.print_usage(sys.stderr)
        print("ci_lock: no command given", file=sys.stderr)
        return EXIT_USAGE

    timeout_s = args.timeout if args.timeout is not None else default_timeout()

    try:
        fd = open_lock(path)
    except OSError as exc:
        print(f"ci_lock: cannot open {path}: {exc}", file=sys.stderr)
        return EXIT_USAGE

    if not acquire(fd, path, timeout_s):
        print(
            f"ci_lock: gave up after {timeout_s:.0f}s waiting for {path}\n"
            f"ci_lock: held by {describe_holder(path)}\n"
            f"ci_lock: another `make ci` owns this host's default keychain; "
            f"wait for it, or kill the holder if it is orphaned.",
            file=sys.stderr,
        )
        return EXIT_BUSY

    write_holder(fd, command)

    # Hand the lock to the payload: the kernel then releases it exactly when
    # the payload dies, and the payload's exit status reaches our caller
    # unmodified because this process is replaced rather than waited on.
    if fd != LOCK_FD:
        os.dup2(fd, LOCK_FD, inheritable=True)
        os.close(fd)
    else:
        os.set_inheritable(fd, True)
    os.environ[LOCK_FD_ENV] = str(LOCK_FD)
    os.environ[LOCK_PATH_ENV] = str(path)

    try:
        os.execvp(command[0], command)
    except OSError as exc:
        print(f"ci_lock: cannot exec {command[0]}: {exc}", file=sys.stderr)
        return EXIT_NOCMD
    raise AssertionError("unreachable: execvp returned without raising")


if __name__ == "__main__":
    sys.exit(main())
