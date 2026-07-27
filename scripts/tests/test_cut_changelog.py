import pathlib
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts/cut_changelog.py"
MAKEFILE = REPO_ROOT / "Makefile"


class CutChangelogTest(unittest.TestCase):
    def run_cut(self, changelog, version="1.5.0", *extra):
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(changelog), version, *extra],
            capture_output=True,
            text=True,
        )

    def test_cut_preserves_staged_notes_and_credit_byte_for_byte(self):
        original = (
            b"# Changelog\n\n"
            b"## [Unreleased]\n\n"
            b"### Fixed\n"
            b"- microphone permission is truthful. reported by Dave Smith.\n"
            b"- another staged note.\n\n"
            b"## [1.4.9] - 2026-07-25\n\n"
            b"### Fixed\n"
            b"- earlier note.\n"
        )
        expected = (
            b"# Changelog\n\n"
            b"## [Unreleased]\n\n"
            b"## [1.5.0] - 2026-07-27\n\n"
            b"### Fixed\n"
            b"- microphone permission is truthful. reported by Dave Smith.\n"
            b"- another staged note.\n\n"
            b"## [1.4.9] - 2026-07-25\n\n"
            b"### Fixed\n"
            b"- earlier note.\n"
        )

        with tempfile.TemporaryDirectory() as tmp:
            changelog = pathlib.Path(tmp) / "CHANGELOG.md"
            changelog.write_bytes(original)
            result = self.run_cut(changelog, "1.5.0", "--date", "2026-07-27")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(changelog.read_bytes(), expected)

    def test_duplicate_unreleased_headings_fail_without_mutation(self):
        original = (
            b"# Changelog\n\n"
            b"## [Unreleased]\n\n"
            b"### Fixed\n- staged.\n\n"
            b"## [Unreleased]\n\n"
            b"## [1.4.9] - 2026-07-25\n"
        )

        with tempfile.TemporaryDirectory() as tmp:
            changelog = pathlib.Path(tmp) / "CHANGELOG.md"
            changelog.write_bytes(original)
            result = self.run_cut(changelog, "1.5.0", "--check-only")

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exactly one", result.stderr)
            self.assertEqual(changelog.read_bytes(), original)

    def test_existing_target_version_fails_without_mutation(self):
        original = (
            b"# Changelog\n\n"
            b"## [Unreleased]\n\n"
            b"### Fixed\n- staged.\n\n"
            b"## [1.5.0] - 2026-07-26\n"
        )

        with tempfile.TemporaryDirectory() as tmp:
            changelog = pathlib.Path(tmp) / "CHANGELOG.md"
            changelog.write_bytes(original)
            result = self.run_cut(changelog, "1.5.0", "--check-only")

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("already contains", result.stderr)
            self.assertEqual(changelog.read_bytes(), original)

    def test_unreleased_must_be_the_first_release_heading(self):
        original = (
            b"# Changelog\n\n"
            b"## [1.4.9] - 2026-07-25\n\n"
            b"### Fixed\n- earlier note.\n\n"
            b"## [Unreleased]\n\n"
            b"### Fixed\n- staged too late.\n"
        )

        with tempfile.TemporaryDirectory() as tmp:
            changelog = pathlib.Path(tmp) / "CHANGELOG.md"
            changelog.write_bytes(original)
            result = self.run_cut(changelog, "1.5.0", "--check-only")

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("first release heading", result.stderr)
            self.assertEqual(changelog.read_bytes(), original)

    def test_empty_unreleased_section_fails_without_mutation(self):
        original = (
            b"# Changelog\n\n"
            b"## [Unreleased]\n\n"
            b"## [1.4.9] - 2026-07-25\n\n"
            b"### Fixed\n- earlier note.\n"
        )

        with tempfile.TemporaryDirectory() as tmp:
            changelog = pathlib.Path(tmp) / "CHANGELOG.md"
            changelog.write_bytes(original)
            result = self.run_cut(changelog, "1.5.0", "--check-only")

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("no staged release-note bullets", result.stderr)
            self.assertEqual(changelog.read_bytes(), original)

    def test_makefile_preflights_changelog_before_plist_mutation(self):
        text = MAKEFILE.read_text(encoding="utf-8")
        start = text.index("bump-release:")
        end = text.index("\nbump-release-journal:", start)
        target = text[start:end]

        self.assertLess(
            target.index("cut_changelog.py CHANGELOG.md \"$(VERSION)\" --check-only"),
            target.index("/usr/bin/plutil -replace"),
        )


if __name__ == "__main__":
    unittest.main()
