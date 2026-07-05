import pathlib
import plistlib
import subprocess
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


class JournalReleaseMetadataTest(unittest.TestCase):
    def test_journal_info_plist_is_reset_for_first_release(self):
        with (REPO_ROOT / "Sources/journal/Info.plist").open("rb") as handle:
            plist = plistlib.load(handle)

        self.assertEqual(plist["CFBundleShortVersionString"], "1.0.0")
        self.assertEqual(plist["CFBundleVersion"], "1")

    def test_sol_and_journal_changelog_1_0_0_blocks_are_distinct(self):
        sol = subprocess.run(
            ["scripts/extract_changelog.sh", "1.0.0", "CHANGELOG.md"],
            cwd=REPO_ROOT,
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        journal = subprocess.run(
            ["scripts/extract_changelog.sh", "1.0.0", "CHANGELOG-journal.md"],
            cwd=REPO_ROOT,
            check=True,
            capture_output=True,
            text=True,
        ).stdout

        self.assertNotEqual(sol, journal)
        self.assertIn("the journal has its own app now", journal)
        self.assertIn("Initial release of Solstone Capture.", sol)


if __name__ == "__main__":
    unittest.main()
