"""The combined mac disk image is composed from published bundles, never built."""
from __future__ import annotations

import os
import pathlib
import sys
import tempfile
import unittest

SCRIPTS = pathlib.Path(__file__).resolve().parents[1]
REPO_ROOT = SCRIPTS.parent
MAKEFILE = REPO_ROOT / "Makefile"
sys.path.insert(0, str(SCRIPTS))

import both_dmg  # noqa: E402


def inputs(sol="2.0.23", journal="2.0.30", build=68):
    return {
        "apps": {
            "solstone": {"version": sol, "build": 98},
            "journal": {"version": journal, "build": build},
        }
    }


def target_block(target):
    text = MAKEFILE.read_text()
    start = text.index(f"\n{target}:") + 1
    end = text.find("\n\n", start)
    return text[start:end]


class ImageIdentityTest(unittest.TestCase):
    def test_name_carries_each_apps_own_version(self):
        self.assertEqual(
            both_dmg.image_name(inputs()),
            "solstone-app-2.0.23-journal-app-2.0.30-build-68.dmg",
        )

    def test_name_changes_with_a_journal_build_only_bump(self):
        self.assertNotEqual(both_dmg.image_name(inputs(build=68)), both_dmg.image_name(inputs(build=69)))

    def test_name_never_names_the_pair_solstone(self):
        name = both_dmg.image_name(inputs())
        self.assertTrue(name.startswith("solstone-app-"))
        self.assertNotIn("solstone-and-journal", name)

    def test_image_and_pointer_live_outside_both_feeds(self):
        key = both_dmg.image_key(both_dmg.image_name(inputs()))
        self.assertTrue(key.startswith("macos-both/releases/"))
        self.assertEqual(both_dmg.LATEST_URL, "https://updates.solstone.app/macos-both/latest.json")
        for app in ("sol", "journal"):
            prefix = both_dmg.APP_CONFIG[app]["prod_prefix"]
            self.assertFalse(key.startswith(prefix + "/"))
            self.assertFalse(both_dmg.LATEST_KEY.startswith(prefix + "/"))


class TreeDigestTest(unittest.TestCase):
    def make_bundle(self, root):
        bundle = pathlib.Path(root) / "x.app"
        (bundle / "Contents/MacOS").mkdir(parents=True)
        (bundle / "Contents/Info.plist").write_text("plist")
        exe = bundle / "Contents/MacOS/x"
        exe.write_text("binary")
        exe.chmod(0o755)
        (bundle / "Contents/Frameworks").mkdir()
        os.symlink("../MacOS", bundle / "Contents/Frameworks/Current")
        return bundle

    def test_same_tree_same_digest(self):
        with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
            self.assertEqual(
                both_dmg.tree_digest(self.make_bundle(a)),
                both_dmg.tree_digest(self.make_bundle(b)),
            )

    def test_body_mode_and_link_changes_are_seen(self):
        with tempfile.TemporaryDirectory() as root:
            bundle = self.make_bundle(root)
            base, _ = both_dmg.tree_digest(bundle)
            (bundle / "Contents/Info.plist").write_text("plisT")
            body, _ = both_dmg.tree_digest(bundle)
            self.assertNotEqual(base, body)
            (bundle / "Contents/MacOS/x").chmod(0o644)
            mode, _ = both_dmg.tree_digest(bundle)
            self.assertNotEqual(body, mode)
            os.unlink(bundle / "Contents/Frameworks/Current")
            os.symlink("../Resources", bundle / "Contents/Frameworks/Current")
            link, _ = both_dmg.tree_digest(bundle)
            self.assertNotEqual(mode, link)


class MakefileNeverRebuildsTest(unittest.TestCase):
    def test_no_target_builds_the_combined_image_from_this_tree(self):
        text = MAKEFILE.read_text()
        self.assertNotIn("\nrelease-dmg-both:", text)
        self.assertNotIn("\nrelease-dmg-smoke-both:", text)
        for target in ("dmg-both", "seal-both", "both-compose", "both-resolve", "both-verify", "both-publish"):
            block = target_block(target)
            with self.subTest(target=target):
                self.assertNotIn("bundle-dist", block)
                self.assertNotIn("release-universal", block)

    def test_dmg_both_packs_the_staged_published_bundles(self):
        block = target_block("dmg-both")
        self.assertIn('"$(BOTH_STAGING)"', block)
        self.assertIn('--volname "install solstone"', block)
        self.assertNotIn("codesign", block)


if __name__ == "__main__":
    unittest.main()
