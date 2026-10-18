"""Exercise the release target with isolated process and signing authorities."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ReleasePreflightTests(unittest.TestCase):
    def preflight(self, processes):
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            fixture = scratch / "processes"
            fixture.write_text(processes)
            for name, body in {
                "ps": 'cat "$PREFLIGHT_PROCESS_FIXTURE"\n',
                "git": 'case "$1" in rev-parse) echo main;; rev-list) echo 0;; esac\n',
            }.items():
                script = scratch / name
                script.write_text("#!/bin/sh\n" + body)
                script.chmod(0o755)
            makefile = scratch / "Makefile"
            makefile.write_text(f"include {ROOT / 'Makefile'}\nsigning-check:\n\t@true\n")
            env = dict(os.environ, PATH=str(scratch) + os.pathsep + os.environ["PATH"],
                       PREFLIGHT_PROCESS_FIXTURE=str(fixture))
            return subprocess.run(["make", "-f", str(makefile), "release-preflight"],
                                  cwd=ROOT, env=env, capture_output=True, text=True,
                                  timeout=30)

    def test_ignores_names_in_unrelated_process_arguments(self):
        result = self.preflight(
            "123 /opt/homebrew/bin/grok --scope mention codesign notarytool sign-and\n"
            "scope continues: make release-dmg and wheel-macos are instructions\n"
            "124 make release-preflight\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("release pre-flight clean", result.stdout)

    def test_refuses_actual_signing_or_runner_programs(self):
        for command in ("/usr/bin/codesign --sign identity artifact",
                        "/usr/bin/xcrun notarytool submit artifact",
                        "/bin/bash /usr/local/bin/wheel-macos artifact",
                        "/usr/bin/python3 /tmp/sign-and-notarize.py artifact",
                        "/tmp/wheel-macos artifact"):
            with self.subTest(command=command):
                result = self.preflight("123 " + command + "\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("stale signing/build processes", result.stdout)


if __name__ == "__main__":
    unittest.main()
