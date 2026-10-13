import importlib.util
import json
import pathlib
import subprocess
import sys
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "release_identity.py"
MAKEFILE = REPO_ROOT / "Makefile"


def load_release_identity():
    spec = importlib.util.spec_from_file_location("release_identity", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module

class ReleaseIdentityTest(unittest.TestCase):
    def test_journal_build_qualified_identity_examples(self):
        module = load_release_identity()

        build14 = module.build_identity(
            "journal", short_version="1.0.12", bundle_version=14
        ).as_dict()
        build15 = module.build_identity(
            "journal", short_version="1.0.12", bundle_version=15, staging=True
        ).as_dict()

        self.assertEqual(build14["github_tag"], "journal-v1.0.12-build-14")
        self.assertEqual(build14["dmg_name"], "journal-1.0.12-build-14.dmg")
        self.assertEqual(
            build14["dmg_key"],
            "journal-macos/releases/v1.0.12/build-14/journal-1.0.12-build-14.dmg",
        )
        self.assertEqual(build14["github_title"], "journal 1.0.12 (build 14)")
        self.assertEqual(build14["appcast_item_title"], "journal 1.0.12 (build 14)")
        self.assertEqual(build14["changelog_key"], "1.0.12 (build 14)")

        self.assertEqual(build15["github_tag"], "journal-v1.0.12-build-15")
        self.assertEqual(build15["dmg_name"], "journal-1.0.12-build-15.dmg")
        self.assertEqual(
            build15["dmg_key"],
            "journal-macos/_staging/releases/v1.0.12/build-15/journal-1.0.12-build-15.dmg",
        )
        self.assertEqual(build15["github_title"], "journal 1.0.12 (build 15)")
        self.assertEqual(build15["appcast_item_title"], "journal 1.0.12 (build 15)")
        self.assertEqual(build15["changelog_key"], "1.0.12 (build 15)")

    def test_sol_identity_is_current_byte_shape(self):
        module = load_release_identity()
        identity = module.build_identity("sol", short_version="1.2.3").as_dict()

        self.assertEqual(identity["github_tag"], "v1.2.3")
        self.assertEqual(identity["dmg_name"], "solstone-1.2.3.dmg")
        self.assertEqual(identity["github_title"], "solstone 1.2.3 for macos")
        self.assertEqual(identity["appcast_item_title"], "solstone 1.2.3")
        self.assertEqual(
            identity["dmg_key"], "solstone-macos/releases/v1.2.3/solstone-1.2.3.dmg"
        )
        self.assertEqual(identity["changelog_key"], "1.2.3")

    def test_cli_default_json_and_field_output(self):
        raw = subprocess.run(
            [
                str(SCRIPT),
                "identity",
                "--app",
                "journal",
                "--version",
                "1.0.12",
                "--build",
                "14",
            ],
            cwd=REPO_ROOT,
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        self.assertEqual(json.loads(raw)["dmg_name"], "journal-1.0.12-build-14.dmg")

        field = subprocess.run(
            [
                str(SCRIPT),
                "identity",
                "--app",
                "journal",
                "--version",
                "1.0.12",
                "--build",
                "14",
                "--field",
                "changelog_key",
            ],
            cwd=REPO_ROOT,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        self.assertEqual(field, "1.0.12 (build 14)")

    def test_sol_cli_rejects_build_argument(self):
        proc = subprocess.run(
            [
                str(SCRIPT),
                "identity",
                "--app",
                "sol",
                "--version",
                "1.2.3",
                "--build",
                "99",
            ],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
        )

        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("sol release identity is version-only", proc.stderr)


class MakefileJournalIdentityContractTest(unittest.TestCase):
    def test_solstone_and_paired_dmg_identity(self):
        text = MAKEFILE.read_text()

        self.assertIn(
            "BOTH_DMG_NAME          ?= $(shell python3 scripts/both_dmg.py name --inputs $(BOTH_DIR)/inputs.json 2>/dev/null)",
            text,
        )
        self.assertIn("DMG_VOLNAME            ?= solstone", text)
        self.assertIn('--volname "install solstone"', text)
        self.assertNotIn("solstone-and-journal-", text)
        self.assertNotIn('--volname "solstone + journal"', text)
        self.assertNotIn("BOTH_DMG_NAME          ?= sol-journal-$(DIST_VERSION).dmg", text)
        self.assertNotIn("DMG_VOLNAME            ?= sol\n", text)
        self.assertNotIn('--volname "sol + journal"', text)


if __name__ == "__main__":
    unittest.main()
