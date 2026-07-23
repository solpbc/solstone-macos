import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
MAKEFILE = REPO_ROOT / "Makefile"
FLAG = "-DSPL_LOGIN_KEYCHAIN"

ADHOC_TARGETS = {
    "release-universal-adhoc",
    "bundle-adhoc",
    "bundle-adhoc-debug",
}

PRODUCTION_TARGETS = {
    "release",
    "release-preflight",
    "release-universal",
    "release-universal-journal",
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
    def test_spl_login_keychain_flag_only_appears_in_adhoc_build_recipe(self):
        blocks = parse_makefile()

        targets_with_flag = sorted(
            name for name, block in blocks.items()
            if FLAG in "\n".join(block["recipe"])
        )

        self.assertEqual(targets_with_flag, ["release-universal-adhoc"])

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


if __name__ == "__main__":
    unittest.main()
