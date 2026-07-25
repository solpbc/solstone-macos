import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import textwrap
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
HELPER = REPO_ROOT / "scripts" / "keychain_search_list.py"
MAKEFILE = REPO_ROOT / "Makefile"
RUN_CI = REPO_ROOT / "scripts" / "run-ci.sh"

CI_KEYCHAIN = "/Users/jer/Library/Keychains/ci-test.keychain-db"
SIGNING_KEYCHAIN = "/Users/jer/Library/Keychains/sol-signing.keychain-db"
LOGIN_KEYCHAIN = "/Users/jer/Library/Keychains/login.keychain-db"
OTHER_KEYCHAIN = "/Users/jer/Library/Keychains/other.keychain-db"
SPACE_KEYCHAIN = "/tmp/keychain space probe/ci space.keychain-db"


def load_keychain_helper():
    spec = importlib.util.spec_from_file_location("keychain_search_list", HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class KeychainSearchListPureTest(unittest.TestCase):
    def test_parse_search_list_preserves_space_bearing_paths(self):
        module = load_keychain_helper()
        output = (
            f'    "{LOGIN_KEYCHAIN}"\n'
            f'    "{SPACE_KEYCHAIN}"\n'
        )

        self.assertEqual(
            module.parse_search_list(output),
            [LOGIN_KEYCHAIN, SPACE_KEYCHAIN],
        )

    def test_parse_default_keychain_reads_single_entry(self):
        module = load_keychain_helper()

        self.assertEqual(
            module.parse_default_keychain(f'    "{LOGIN_KEYCHAIN}"\n'),
            LOGIN_KEYCHAIN,
        )
        self.assertIsNone(module.parse_default_keychain(""))

    def test_prepend_unique_adds_to_head_and_dedupes(self):
        module = load_keychain_helper()

        self.assertEqual(
            module.prepend_unique([LOGIN_KEYCHAIN, OTHER_KEYCHAIN], SIGNING_KEYCHAIN),
            [SIGNING_KEYCHAIN, LOGIN_KEYCHAIN, OTHER_KEYCHAIN],
        )
        self.assertEqual(
            module.prepend_unique([LOGIN_KEYCHAIN, SIGNING_KEYCHAIN, OTHER_KEYCHAIN], SIGNING_KEYCHAIN),
            [SIGNING_KEYCHAIN, LOGIN_KEYCHAIN, OTHER_KEYCHAIN],
        )
        self.assertEqual(
            module.prepend_unique([SIGNING_KEYCHAIN, LOGIN_KEYCHAIN], SIGNING_KEYCHAIN),
            [SIGNING_KEYCHAIN, LOGIN_KEYCHAIN],
        )

    def test_remove_exact_removes_only_owned_keychain(self):
        module = load_keychain_helper()

        self.assertEqual(
            module.remove_exact([CI_KEYCHAIN, LOGIN_KEYCHAIN, OTHER_KEYCHAIN], CI_KEYCHAIN),
            [LOGIN_KEYCHAIN, OTHER_KEYCHAIN],
        )
        self.assertEqual(
            module.remove_exact([CI_KEYCHAIN, LOGIN_KEYCHAIN, CI_KEYCHAIN], CI_KEYCHAIN),
            [LOGIN_KEYCHAIN],
        )

    def test_set_search_list_argv_keeps_space_path_as_one_argument(self):
        module = load_keychain_helper()

        self.assertEqual(
            module.set_search_list_argv([LOGIN_KEYCHAIN, SPACE_KEYCHAIN]),
            [
                "security",
                "list-keychains",
                "-d",
                "user",
                "-s",
                LOGIN_KEYCHAIN,
                SPACE_KEYCHAIN,
            ],
        )


class KeychainSearchListSubprocessTest(unittest.TestCase):
    def make_fake_security(self, *, search=None, default=LOGIN_KEYCHAIN):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = pathlib.Path(tmp.name)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        (root / "search.json").write_text(json.dumps(search or []), encoding="utf-8")
        (root / "default.txt").write_text(default or "", encoding="utf-8")

        security = bin_dir / "security"
        security.write_text(
            "#!" + sys.executable + "\n" + textwrap.dedent(
                """\
                import json
                import os
                import pathlib
                import sys

                root = pathlib.Path(os.environ["FAKE_SECURITY_ROOT"])
                args = sys.argv[1:]

                def read_json(name):
                    return json.loads((root / name).read_text(encoding="utf-8"))

                def write_json(name, value):
                    (root / name).write_text(json.dumps(value), encoding="utf-8")

                def log(kind):
                    with (root / "calls.jsonl").open("a", encoding="utf-8") as handle:
                        handle.write(json.dumps({"kind": kind, "args": args}) + "\\n")

                def emit(paths):
                    for path in paths:
                        print(f'    "{path}"')

                if args == ["list-keychains", "-d", "user"]:
                    log("list-read")
                    emit(read_json("search.json"))
                    raise SystemExit(0)

                if args[:4] == ["list-keychains", "-d", "user", "-s"]:
                    log("list-write")
                    write_json("search.json", args[4:])
                    raise SystemExit(0)

                if args == ["default-keychain", "-d", "user"]:
                    log("default-read")
                    default = (root / "default.txt").read_text(encoding="utf-8")
                    if default:
                        emit([default])
                    raise SystemExit(0)

                if args[:4] == ["default-keychain", "-d", "user", "-s"]:
                    log("default-write")
                    (root / "default.txt").write_text(args[4] if len(args) > 4 else "", encoding="utf-8")
                    raise SystemExit(0)

                print(f"unexpected security args: {args}", file=sys.stderr)
                raise SystemExit(99)
                """
            ),
            encoding="utf-8",
        )
        security.chmod(0o755)
        return root, bin_dir

    def run_helper(self, root, bin_dir, *args):
        env = os.environ.copy()
        env["FAKE_SECURITY_ROOT"] = str(root)
        # Replace PATH so a missing fake cannot fall through to the real security binary.
        env["PATH"] = str(bin_dir)
        return subprocess.run(
            [sys.executable, str(HELPER), *args],
            cwd=REPO_ROOT,
            env=env,
            text=True,
            capture_output=True,
        )

    def read_search(self, root):
        return json.loads((root / "search.json").read_text(encoding="utf-8"))

    def read_default(self, root):
        return (root / "default.txt").read_text(encoding="utf-8")

    def read_calls(self, root):
        calls_path = root / "calls.jsonl"
        if not calls_path.exists():
            return []
        return [
            json.loads(line)
            for line in calls_path.read_text(encoding="utf-8").splitlines()
        ]

    def test_prepend_cli_adds_signing_keychain_without_dropping_entries(self):
        root, bin_dir = self.make_fake_security(search=[LOGIN_KEYCHAIN, OTHER_KEYCHAIN])

        result = self.run_helper(root, bin_dir, "prepend", SIGNING_KEYCHAIN)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_search(root), [SIGNING_KEYCHAIN, LOGIN_KEYCHAIN, OTHER_KEYCHAIN])

    def test_prepend_cli_is_idempotent(self):
        root, bin_dir = self.make_fake_security(search=[SIGNING_KEYCHAIN, LOGIN_KEYCHAIN])

        first = self.run_helper(root, bin_dir, "prepend", SIGNING_KEYCHAIN)
        second = self.run_helper(root, bin_dir, "prepend", SIGNING_KEYCHAIN)

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.read_search(root), [SIGNING_KEYCHAIN, LOGIN_KEYCHAIN])
        self.assertEqual(
            [call for call in self.read_calls(root) if call["kind"] == "list-write"],
            [],
        )

    def test_prepend_cli_moves_existing_signing_keychain_to_head(self):
        root, bin_dir = self.make_fake_security(search=[LOGIN_KEYCHAIN, SIGNING_KEYCHAIN, OTHER_KEYCHAIN])

        result = self.run_helper(root, bin_dir, "prepend", SIGNING_KEYCHAIN)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_search(root), [SIGNING_KEYCHAIN, LOGIN_KEYCHAIN, OTHER_KEYCHAIN])

    def test_prepend_cli_keeps_space_path_as_one_security_argument(self):
        root, bin_dir = self.make_fake_security(search=[LOGIN_KEYCHAIN])

        result = self.run_helper(root, bin_dir, "prepend", SPACE_KEYCHAIN)

        self.assertEqual(result.returncode, 0, result.stderr)
        write_calls = [call for call in self.read_calls(root) if call["kind"] == "list-write"]
        self.assertEqual(len(write_calls), 1)
        self.assertEqual(write_calls[0]["args"][4:], [SPACE_KEYCHAIN, LOGIN_KEYCHAIN])

    def test_remove_cli_retains_foreign_entry_added_mid_run(self):
        root, bin_dir = self.make_fake_security(search=[CI_KEYCHAIN, LOGIN_KEYCHAIN, OTHER_KEYCHAIN])

        result = self.run_helper(root, bin_dir, "remove", CI_KEYCHAIN)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_search(root), [LOGIN_KEYCHAIN, OTHER_KEYCHAIN])

    def test_remove_cli_skips_empty_write_and_warns(self):
        root, bin_dir = self.make_fake_security(search=[CI_KEYCHAIN])

        result = self.run_helper(root, bin_dir, "remove", CI_KEYCHAIN)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_search(root), [CI_KEYCHAIN])
        self.assertIn("skipping keychain search-list write", result.stderr)
        self.assertEqual(
            [call for call in self.read_calls(root) if call["kind"] == "list-write"],
            [],
        )

    def test_restore_default_if_current_restores_prior_when_still_owned(self):
        root, bin_dir = self.make_fake_security(default=CI_KEYCHAIN)

        result = self.run_helper(
            root,
            bin_dir,
            "restore-default-if-current",
            CI_KEYCHAIN,
            LOGIN_KEYCHAIN,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_default(root), LOGIN_KEYCHAIN)
        self.assertEqual(
            [call["args"] for call in self.read_calls(root) if call["kind"] == "default-write"],
            [["default-keychain", "-d", "user", "-s", LOGIN_KEYCHAIN]],
        )

    def test_restore_default_if_current_leaves_changed_default(self):
        root, bin_dir = self.make_fake_security(default=OTHER_KEYCHAIN)

        result = self.run_helper(
            root,
            bin_dir,
            "restore-default-if-current",
            CI_KEYCHAIN,
            LOGIN_KEYCHAIN,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_default(root), OTHER_KEYCHAIN)
        self.assertIn("leaving it unchanged", result.stderr)
        self.assertEqual(
            [call for call in self.read_calls(root) if call["kind"] == "default-write"],
            [],
        )


class KeychainSearchListStaticTest(unittest.TestCase):
    def test_unlock_signing_uses_shared_helper_not_direct_security_writer(self):
        content = MAKEFILE.read_text(encoding="utf-8")
        self.assertIn("KEYCHAIN_SEARCH_LIST   := python3 scripts/keychain_search_list.py", content)
        block = content.split("unlock-signing:", 1)[1].split("\n\n", 1)[0]

        self.assertIn('@$(KEYCHAIN_SEARCH_LIST) prepend "$(SIGNING_KEYCHAIN)" >/dev/null', block)
        self.assertNotIn("security list-keychains", block)
        self.assertNotIn(" list-keychains -s ", block)

    def test_run_ci_uses_shared_helper_for_search_list_mutations(self):
        content = RUN_CI.read_text(encoding="utf-8")

        self.assertIn('python3 scripts/keychain_search_list.py prepend "$TEST_KC"', content)
        self.assertIn('python3 scripts/keychain_search_list.py remove "$TEST_KC"', content)
        self.assertNotIn("PRIOR_LIST", content)
        self.assertNotIn("xargs", content)
        self.assertNotIn("tr -d", content)
        self.assertNotIn("security list-keychains -d user -s", content)


if __name__ == "__main__":
    unittest.main()
