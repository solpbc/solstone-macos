import pathlib
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


class ExtractChangelogTest(unittest.TestCase):
    """The shared changelog extractor, used by both apps' release tooling."""

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


if __name__ == "__main__":
    unittest.main()
