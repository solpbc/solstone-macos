import pathlib
import plistlib
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
MAKEFILE = REPO_ROOT / "Makefile"


class JournalReleaseMetadataTest(unittest.TestCase):
    def test_journal_info_plist_is_reset_for_first_release(self):
        with (REPO_ROOT / "Sources/journal/Info.plist").open("rb") as handle:
            plist = plistlib.load(handle)

        import re as _re
        self.assertRegex(plist["CFBundleShortVersionString"], _re.compile(r"^2\.\d+\.\d+$"))
        self.assertGreaterEqual(int(plist["CFBundleVersion"]), 1)

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

    def test_extract_changelog_pair_qualified_blocks_are_distinct(self):
        with tempfile.TemporaryDirectory() as tmp:
            changelog = pathlib.Path(tmp) / "CHANGELOG-journal.md"
            changelog.write_text(
                "# journal\n\n"
                "## [1.0.12 (build 15)] - 2026-07-23\n\n"
                "### Fixed\n"
                "- build 15 only\n\n"
                "## [1.0.12 (build 14)] - 2026-07-22\n\n"
                "### Fixed\n"
                "- build 14 only\n",
                encoding="utf-8",
            )

            build14 = subprocess.run(
                ["scripts/extract_changelog.sh", "1.0.12 (build 14)", str(changelog)],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            ).stdout
            build15 = subprocess.run(
                ["scripts/extract_changelog.sh", "1.0.12 (build 15)", str(changelog)],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            ).stdout

        self.assertIn("build 14 only", build14)
        self.assertNotIn("build 15 only", build14)
        self.assertIn("build 15 only", build15)
        self.assertNotIn("build 14 only", build15)

    def test_extract_changelog_missing_key_names_requested_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            changelog = pathlib.Path(tmp) / "CHANGELOG-journal.md"
            changelog.write_text("# journal\n\n## [1.0.12 (build 14)] - 2026-07-22\n", encoding="utf-8")

            proc = subprocess.run(
                ["scripts/extract_changelog.sh", "1.0.12 (build 15)", str(changelog)],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
            )

        self.assertNotEqual(proc.returncode, 0)
        self.assertIn(str(changelog), proc.stderr)
        self.assertIn("no entry for key 1.0.12 (build 15)", proc.stderr)
        self.assertNotIn("CHANGELOG.md entry for version", proc.stderr)


class JournalBumpMakefileContractTest(unittest.TestCase):
    def target_block(self, target):
        text = MAKEFILE.read_text()
        start = text.index(f"{target}:")
        search_from = start + 1
        while True:
            candidate = text.find("\n", search_from)
            if candidate == -1:
                return text[start:]
            line_start = candidate + 1
            if line_start >= len(text):
                return text[start:]
            if text[line_start] not in ("\t", " ", "\n", "#"):
                colon = text.find(":", line_start, text.find("\n", line_start))
                if colon != -1:
                    return text[start:candidate]
            search_from = candidate + 1

    def test_bump_release_journal_checks_pin_before_writes(self):
        block = self.target_block("bump-release-journal")
        self.assertLess(
            block.index("check-journal-prep"),
            block.index("plutil -replace CFBundleShortVersionString"),
        )

    def test_bump_release_journal_uses_pair_qualified_changelog_key(self):
        block = self.target_block("bump-release-journal")
        self.assertIn("--build \"$(BUILD)\" --field changelog_key", block)
        self.assertIn("grep -Fq \"## [$$CHANGELOG_KEY]\"", block)
        self.assertIn("awk -v k=\"$$CHANGELOG_KEY\"", block)
        self.assertIn("BUILD=$(BUILD) must be strictly greater", block)


if __name__ == "__main__":
    unittest.main()
