import os
import pathlib
import subprocess
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "github-release.sh"


class GithubReleaseDryRunTest(unittest.TestCase):
    def run_dry(self, *args):
        env = os.environ.copy()
        env["GITHUB_RELEASE_DRY_RUN"] = "1"
        return subprocess.run(
            ["bash", str(SCRIPT), *args],
            cwd=REPO_ROOT,
            env=env,
            check=True,
            capture_output=True,
            text=True,
        ).stdout

    def test_sol_release_shape(self):
        output = self.run_dry("--app", "sol", "1.2.3")

        self.assertIn("TAG=v1.2.3", output)
        self.assertIn("DMG=sol-1.2.3.dmg", output)
        self.assertIn("TITLE=solstone-macos 1.2.3", output)
        self.assertIn("CHANGELOG=CHANGELOG.md", output)
        self.assertIn("LATEST_ARGS=(default)", output)
        self.assertNotIn("--latest=false", output)

    def test_journal_release_shape(self):
        output = self.run_dry("--app", "journal", "1.0.0")

        self.assertIn("TAG=journal-v1.0.0", output)
        self.assertIn("DMG=journal-1.0.0.dmg", output)
        self.assertIn("TITLE=journal-macos 1.0.0", output)
        self.assertIn("CHANGELOG=CHANGELOG-journal.md", output)
        self.assertIn("LATEST_ARGS=--latest=false", output)
        self.assertIn("--latest=false", output)


if __name__ == "__main__":
    unittest.main()
