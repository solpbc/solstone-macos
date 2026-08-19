import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
CI_LOCK = REPO_ROOT / "scripts" / "ci_lock.py"
RUN_CI = REPO_ROOT / "scripts" / "run-ci.sh"

EXIT_BUSY = 75
EXIT_USAGE = 64


def wrapper(lock: pathlib.Path, *args: str) -> list[str]:
    return [sys.executable, str(CI_LOCK), "--lock", str(lock), *args]


def wait_for(predicate, timeout_s: float = 10.0, interval_s: float = 0.02) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval_s)
    return False


class CiLockTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = pathlib.Path(self._tmp.name)
        self.lock = self.tmp / "ci.lock"
        self.addCleanup(self._tmp.cleanup)

    def start_holder(self, hold_s: float = 30.0) -> subprocess.Popen:
        """Start a wrapper whose payload holds the lock until we kill it."""
        ready = self.tmp / "holder.ready"
        proc = subprocess.Popen(
            wrapper(self.lock, "--timeout", "10", "--")
            + [
                sys.executable,
                "-c",
                "import pathlib,sys,time\n"
                "pathlib.Path(sys.argv[1]).write_text('up')\n"
                "time.sleep(float(sys.argv[2]))\n",
                str(ready),
                str(hold_s),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.addCleanup(self._reap, proc)
        self.assertTrue(
            wait_for(ready.exists), "holder never signalled that it was running"
        )
        return proc

    def _reap(self, proc: subprocess.Popen) -> None:
        if proc.poll() is None:
            proc.kill()
        proc.wait(timeout=10)
        for stream in (proc.stdout, proc.stderr):
            if stream is not None:
                stream.close()

    # --- the mutex itself -------------------------------------------------

    def test_second_run_waits_and_then_reports_the_holder(self):
        holder = self.start_holder()
        completed = subprocess.run(
            wrapper(self.lock, "--timeout", "1", "--")
            + [sys.executable, "-c", "raise SystemExit(0)"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, EXIT_BUSY)
        self.assertIn(f"pid {holder.pid}", completed.stderr)
        self.assertIn("gave up after", completed.stderr)

    def test_concurrent_runs_do_not_interleave(self):
        marks = self.tmp / "marks"
        marks.write_text("")
        payload = (
            "import pathlib,sys,time\n"
            "p = pathlib.Path(sys.argv[1])\n"
            "tag = sys.argv[2]\n"
            "with p.open('a') as fh: fh.write(f'{tag}-in\\n')\n"
            "time.sleep(0.6)\n"
            "with p.open('a') as fh: fh.write(f'{tag}-out\\n')\n"
        )
        procs = [
            subprocess.Popen(
                wrapper(self.lock, "--timeout", "30", "--")
                + [sys.executable, "-c", payload, str(marks), tag],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            for tag in ("a", "b")
        ]
        for proc in procs:
            self.assertEqual(proc.wait(timeout=60), 0)

        lines = marks.read_text().split()
        self.assertEqual(len(lines), 4, lines)
        # Whichever ran first must have finished before the other started.
        first = lines[0].split("-")[0]
        second = "b" if first == "a" else "a"
        self.assertEqual(
            lines,
            [f"{first}-in", f"{first}-out", f"{second}-in", f"{second}-out"],
        )

    def test_sigkilled_holder_leaves_no_stale_lock(self):
        holder = self.start_holder()
        os.kill(holder.pid, signal.SIGKILL)
        holder.wait(timeout=10)

        completed = subprocess.run(
            wrapper(self.lock, "--timeout", "5", "--")
            + [sys.executable, "-c", "raise SystemExit(0)"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)

    # --- the wrapper must be transparent ----------------------------------

    def test_payload_exit_status_reaches_the_caller(self):
        for expected in (0, 1, 7):
            with self.subTest(status=expected):
                completed = subprocess.run(
                    wrapper(self.lock, "--timeout", "5", "--")
                    + [sys.executable, "-c", f"raise SystemExit({expected})"],
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(completed.returncode, expected, completed.stderr)

    def test_payload_inherits_the_lock_on_the_advertised_fd(self):
        completed = subprocess.run(
            wrapper(self.lock, "--timeout", "5", "--")
            + [
                sys.executable,
                "-c",
                "import os\n"
                "fd = os.environ['SOLSTONE_CI_LOCK_FD']\n"
                "print(fd, os.path.exists(f'/dev/fd/{fd}'))\n",
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout.strip(), "9 True")

    def test_no_command_is_a_usage_error(self):
        completed = subprocess.run(
            wrapper(self.lock), capture_output=True, text=True
        )
        self.assertEqual(completed.returncode, EXIT_USAGE)
        self.assertIn("no command given", completed.stderr)

    # --- operator surface --------------------------------------------------

    def test_status_distinguishes_free_from_held(self):
        free = subprocess.run(
            wrapper(self.lock, "--status"), capture_output=True, text=True
        )
        self.assertEqual(free.returncode, 0)
        self.assertIn("free:", free.stdout)

        holder = self.start_holder()
        held = subprocess.run(
            wrapper(self.lock, "--status"), capture_output=True, text=True
        )
        self.assertEqual(held.returncode, EXIT_BUSY)
        self.assertIn("held:", held.stdout)
        self.assertIn(f"pid {holder.pid}", held.stdout)


class RunCiLockWiringTest(unittest.TestCase):
    """run-ci.sh must take the lock before it touches any shared state."""

    def setUp(self):
        self.content = RUN_CI.read_text(encoding="utf-8")

    def test_lock_is_taken_before_the_shared_log_is_truncated(self):
        exec_at = self.content.index('exec python3 "$REPO_ROOT/scripts/ci_lock.py"')
        truncate_at = self.content.index(': > "$CI_LOG"')
        keychain_at = self.content.index('security delete-keychain "$TEST_KC"')
        self.assertLess(exec_at, truncate_at)
        self.assertLess(exec_at, keychain_at)

    def test_guard_tests_the_fd_not_just_the_variable(self):
        self.assertIn('[ ! -e "/dev/fd/${SOLSTONE_CI_LOCK_FD}" ]', self.content)

    def test_test_phase_closes_the_lock_fd_in_children(self):
        self.assertIn("run_tests 9>&- | tee -a \"$CI_LOG\" 9>&-", self.content)


class RunCiCrashRecoveryTest(unittest.TestCase):
    """A killed run must not leave the host without a default keychain.

    Deleting the keychain that holds the user default empties the slot rather
    than falling back, and every later run then dies reading it.
    """

    def setUp(self):
        self.content = RUN_CI.read_text(encoding="utf-8")

    def test_default_slot_is_refilled_before_the_leftover_is_deleted(self):
        repair_at = self.content.index("if needs_default_repair; then")
        delete_at = self.content.index(
            'security delete-keychain "$TEST_KC" 2>/dev/null || true'
        )
        self.assertLess(repair_at, delete_at)

    def test_repair_covers_both_wedged_states(self):
        block = self.content.split("needs_default_repair() {", 1)[1].split("}", 1)[0]
        # An empty default slot (a host already wedged) and our own leftover
        # keychain sitting in it are both repairable; anything else is left be.
        self.assertIn('"") return 0 ;;', block)
        self.assertIn('*"$TEST_KC"*) return 0 ;;', block)
        self.assertIn("*) return 1 ;;", block)


if __name__ == "__main__":
    unittest.main()
