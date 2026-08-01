import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
MAKEFILE = REPO_ROOT / "Makefile"
INFO_PLIST = REPO_ROOT / "Sources" / "solstone" / "Info.plist"
FLAG = "-D" + "SPL_LOGIN" + "_KEYCHAIN"
MARKER_KEY = "SolstoneSPLKeychainPlane"

ADHOC_TARGETS = {
    "release-arm64-adhoc",
    "bundle-adhoc",
    "bundle-adhoc-debug",
}

PRODUCTION_TARGETS = {
    "release",
    "release-preflight",
    "release-arm64",
    "release-arm64-journal",
    "bundle-dist",
    "bundle-dist-journal",
    "dmg",
    "dmg-journal",
    "dmg-both",
    "notarize",
    "notarize-journal",
    "notarize-both",
    "staple",
    "staple-journal",
    "staple-both",
    "verify-notarization",
    "verify-notarization-journal",
    "verify-notarization-both",
    "release-dmg",
    "release-dmg-journal",
    "release-dmg-both",
    "release-dmg-smoke",
    "release-dmg-smoke-journal",
    "release-dmg-smoke-both",
    "publish-preflight",
    "publish-appcast",
    "publish-appcast-staging",
    "publish-appcast-journal",
    "publish-appcast-journal-staging",
    "github-release",
    "github-release-journal",
    "bump-release",
    "bump-release-journal",
}


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


class AdhocBuildIsolationTest(unittest.TestCase):
    def test_spl_login_keychain_flag_appears_nowhere(self):
        offenders = []
        for path in REPO_ROOT.rglob("*"):
            if not path.is_file():
                continue
            if any(part in {".git", ".build", "solstone.app", "journal.app"} for part in path.parts):
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            if FLAG in text:
                offenders.append(path.relative_to(REPO_ROOT).as_posix())

        self.assertEqual(offenders, [])

    def test_login_keychain_marker_only_appears_in_adhoc_bundle_recipe(self):
        blocks = parse_makefile()

        targets_with_marker = sorted(
            name for name, block in blocks.items()
            if MARKER_KEY in "\n".join(block["recipe"])
        )

        self.assertEqual(targets_with_marker, ["bundle-adhoc"])

    def test_login_keychain_marker_is_sealed_by_app_signature(self):
        blocks = parse_makefile()
        recipe = blocks["bundle-adhoc"]["recipe"]
        marker_index = next(
            (
                index for index, line in enumerate(recipe)
                if "plutil -insert" in line and MARKER_KEY in line
            ),
            None,
        )
        app_codesign_index = None

        for index, line in enumerate(recipe):
            if not line.lstrip().startswith("@codesign --force"):
                continue
            command_lines = [line]
            while command_lines[-1].rstrip().endswith("\\"):
                next_index = index + len(command_lines)
                if next_index >= len(recipe):
                    break
                command_lines.append(recipe[next_index])
            final_argument = command_lines[-1].strip()
            if final_argument == "solstone.app":
                app_codesign_index = index
                break

        self.assertIsNotNone(
            marker_index,
            "bundle-adhoc must insert the login-keychain marker into Info.plist",
        )
        self.assertIsNotNone(
            app_codesign_index,
            "bundle-adhoc app bundle codesign command not found; cannot prove the marker is sealed",
        )
        self.assertLess(
            marker_index,
            app_codesign_index,
            "bundle-adhoc inserts the login-keychain marker after app signing; "
            "the marker must be sealed by the signature so ad-hoc builds stay on the login-keychain plane",
        )

    def test_shared_info_plist_does_not_contain_login_keychain_marker(self):
        self.assertNotIn(MARKER_KEY, INFO_PLIST.read_text(encoding="utf-8"))

    def test_production_targets_do_not_reference_adhoc_targets(self):
        blocks = parse_makefile()
        missing = sorted(PRODUCTION_TARGETS - blocks.keys())
        self.assertEqual(missing, [])

        for target in sorted(PRODUCTION_TARGETS):
            block = blocks[target]
            recipe = "\n".join(block["recipe"])

            for adhoc_target in ADHOC_TARGETS:
                self.assertNotRegex(
                    block["prereqs"],
                    rf"(^|\s){re.escape(adhoc_target)}(\s|$)",
                    target,
                )
                self.assertNotIn(f"$(MAKE) {adhoc_target}", recipe, target)

    def test_bundle_adhoc_debug_reenters_bundle_adhoc(self):
        blocks = parse_makefile()
        self.assertIn(
            "$(MAKE) bundle-adhoc",
            "\n".join(blocks["bundle-adhoc-debug"]["recipe"]),
        )

    def test_production_bundle_keeps_keychain_access_group_gate(self):
        blocks = parse_makefile()
        recipe = "\n".join(blocks["bundle-dist"]["recipe"])
        self.assertIn("codesign -d --entitlements", recipe)
        self.assertIn("grep -q", recipe)
        self.assertIn("keychain-access-group entitlement missing", recipe)

    def test_distributed_builds_are_apple_silicon_only(self):
        blocks = parse_makefile()

        for target in (
            "release-arm64",
            "release-arm64-adhoc",
            "release-arm64-journal",
        ):
            recipe = "\n".join(blocks[target]["recipe"])
            self.assertIn("--arch arm64", recipe, target)
            self.assertNotIn("--arch x86_64", recipe, target)

        self.assertIn("release-arm64", blocks["bundle-dist"]["prereqs"])
        self.assertIn("release-arm64-journal", blocks["bundle-dist-journal"]["prereqs"])

        for target, executable in (
            ("verify-notarization", "solstone.app/Contents/MacOS/solstone"),
            ("verify-notarization-journal", "journal.app/Contents/MacOS/journal"),
        ):
            recipe = "\n".join(blocks[target]["recipe"])
            self.assertIn(f'lipo -archs {executable})" = "arm64"', recipe, target)


if __name__ == "__main__":
    unittest.main()
