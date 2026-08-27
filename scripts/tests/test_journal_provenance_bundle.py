import hashlib
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest


# scripts/run-ci.sh runs this Python suite only after swift test exits. That ordering is
# load-bearing: this test's child make process must own SwiftPM's .build lock itself.
REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
MAKEFILE = REPO_ROOT / "Makefile"
SOURCE_PROVENANCE = REPO_ROOT / "Sources/journal/Resources/runtime-entry-candidate-provenance.json"
APPLE_RELEASE = REPO_ROOT / ".build/apple/Products/Release"
JOURNAL_APP = REPO_ROOT / "journal.app"
APPLE_OUTPUTS = [
    APPLE_RELEASE / "journal",
    APPLE_RELEASE / "solstone-watchdog",
    APPLE_RELEASE / "solstone_journal.bundle",
    APPLE_RELEASE / "solstone_JournalMarkKit.bundle",
]


def parse_makefile():
    blocks = {}
    current = None
    target_re = re.compile(r"^([A-Za-z0-9_.-]+):(.*)$")

    for line in MAKEFILE.read_text(encoding="utf-8").splitlines():
        match = target_re.match(line)
        if match and not line.startswith("."):
            current = blocks[match.group(1)] = {
                "prereqs": match.group(2),
                "recipe": [],
            }
            continue

        if current is not None and line.startswith("\t"):
            current["recipe"].append(line)

    return blocks


def remove_path(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class JournalProvenanceBundleTest(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="journal-provenance-bundle-",
            dir="/var/tmp",
        )
        self.saved_journal_app = pathlib.Path(self.temporary_directory.name) / "journal.app"
        self.had_journal_app = JOURNAL_APP.exists() or JOURNAL_APP.is_symlink()
        if self.had_journal_app:
            shutil.move(str(JOURNAL_APP), str(self.saved_journal_app))

    def tearDown(self):
        remove_path(JOURNAL_APP)
        if self.had_journal_app:
            shutil.move(str(self.saved_journal_app), str(JOURNAL_APP))
        self.temporary_directory.cleanup()

    def test_unsigned_assembly_refreshes_apple_products_and_copies_provenance(self):
        for output in APPLE_OUTPUTS:
            remove_path(output)

        result = subprocess.run(
            ["make", "journal-app-unsigned"],
            cwd=REPO_ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        journal = APPLE_RELEASE / "journal"
        watchdog = APPLE_RELEASE / "solstone-watchdog"
        product_provenance = (
            APPLE_RELEASE
            / "solstone_journal.bundle/Contents/Resources/Resources/runtime-entry-candidate-provenance.json"
        )
        assembled_provenance = (
            JOURNAL_APP
            / "Contents/Resources/solstone_journal.bundle/Contents/Resources/Resources/runtime-entry-candidate-provenance.json"
        )

        self.assertTrue(journal.is_file())
        self.assertTrue(watchdog.is_file())
        self.assertTrue(product_provenance.is_file())
        self.assertTrue(assembled_provenance.is_file())
        self.assertEqual(
            sha256(SOURCE_PROVENANCE),
            sha256(product_provenance),
        )
        self.assertEqual(
            sha256(SOURCE_PROVENANCE),
            sha256(assembled_provenance),
        )

        blocks = parse_makefile()
        journal_bundle_copy = (
            "\t@cp -r .build/apple/Products/Release/solstone_journal.bundle "
            "journal.app/Contents/Resources/"
        )
        mark_bundle_copy = (
            "\t@cp -r .build/apple/Products/Release/solstone_JournalMarkKit.bundle "
            "journal.app/Contents/Resources/"
        )
        makefile_text = MAKEFILE.read_text(encoding="utf-8")
        assembly_recipe = "\n".join(blocks["assemble-journal-app"]["recipe"])
        distribution_recipe = "\n".join(blocks["bundle-dist-journal"]["recipe"])

        self.assertEqual(makefile_text.count(journal_bundle_copy), 1)
        self.assertEqual(makefile_text.count(mark_bundle_copy), 1)
        self.assertIn(journal_bundle_copy, assembly_recipe)
        self.assertIn(mark_bundle_copy, assembly_recipe)
        self.assertNotIn(journal_bundle_copy, distribution_recipe)
        self.assertNotIn(mark_bundle_copy, distribution_recipe)
        self.assertEqual(blocks["journal-app-unsigned"]["recipe"], [])
        self.assertEqual(
            blocks["journal-app-unsigned"]["prereqs"].split(),
            ["assemble-journal-app"],
        )

        prohibited = {"unlock-signing", "signing-check", "journal-native-runtime"}
        self.assertTrue(prohibited.isdisjoint(self.transitive_prerequisites(
            "journal-app-unsigned",
            blocks,
        )))

    def transitive_prerequisites(self, target, blocks):
        visited = set()

        def visit(name):
            if name in visited:
                return
            visited.add(name)
            for prerequisite in blocks.get(name, {}).get("prereqs", "").split():
                visit(prerequisite)

        visit(target)
        return visited


if __name__ == "__main__":
    unittest.main()
