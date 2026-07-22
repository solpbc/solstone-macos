import json
import os
import pathlib
import plistlib
import subprocess
import tempfile
import textwrap
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "github-release.sh"
IDENTITY = REPO_ROOT / "scripts" / "release_identity.py"
EXTRACT = REPO_ROOT / "scripts" / "extract_changelog.sh"
HEAD = "a" * 40
OTHER = "b" * 40
EXPECTED_DMG_SHA256 = "2bbea039f194420fd24683a7cd663ce39fec7292698e3f59588dfd9a1779620f"


class GithubReleaseDryRunTest(unittest.TestCase):
    def run_dry(self, *args):
        env = os.environ.copy()
        env["GITHUB_RELEASE_DRY_RUN"] = "1"
        return subprocess.run(
            ["bash", str(SCRIPT), *args],
            cwd=REPO_ROOT,
            env=env,
            check=True,
            capture_output=True,
            text=True,
        ).stdout

    def test_sol_release_shape(self):
        output = self.run_dry("--app", "sol", "1.2.3")

        self.assertEqual(
            output,
            "APP=sol\n"
            "VERSION=1.2.3\n"
            "TAG=v1.2.3\n"
            "DMG=sol-1.2.3.dmg\n"
            "TITLE=solstone-macos 1.2.3\n"
            "CHANGELOG=CHANGELOG.md\n"
            "LATEST_ARGS=(default)\n"
            "git tag -a v1.2.3 -m 'solstone-macos 1.2.3'\n"
            "git push origin v1.2.3\n"
            "gh release create v1.2.3 sol-1.2.3.dmg --title 'solstone-macos 1.2.3' --notes-file <notes> \n",
        )

    def test_journal_release_shape(self):
        output = self.run_dry("--app", "journal", "--build", "14", "1.0.12")

        self.assertEqual(
            output,
            "APP=journal\n"
            "VERSION=1.0.12\n"
            "BUILD=14\n"
            "TAG=journal-v1.0.12-build-14\n"
            "DMG=journal-1.0.12-build-14.dmg\n"
            "TITLE=journal 1.0.12 (build 14)\n"
            "CHANGELOG=CHANGELOG-journal.md\n"
            "CHANGELOG_KEY=1.0.12 (build 14)\n"
            "LATEST_ARGS=--latest=false\n"
            "git tag -a journal-v1.0.12-build-14 -m 'journal 1.0.12 (build 14)'\n"
            "git push origin journal-v1.0.12-build-14\n"
            "gh release create journal-v1.0.12-build-14 journal-1.0.12-build-14.dmg --title 'journal 1.0.12 (build 14)' --notes-file <notes> --latest=false\n",
        )

    def test_journal_release_shape_build_15(self):
        output = self.run_dry("--app", "journal", "--build", "15", "1.0.12")

        self.assertIn("BUILD=15\n", output)
        self.assertIn("TAG=journal-v1.0.12-build-15\n", output)
        self.assertIn("DMG=journal-1.0.12-build-15.dmg\n", output)
        self.assertIn("TITLE=journal 1.0.12 (build 15)\n", output)
        self.assertIn("CHANGELOG_KEY=1.0.12 (build 15)\n", output)


class GithubReleaseRecoveryTest(unittest.TestCase):
    def write_executable(self, path, body):
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)

    def write_plist(self, path, version, build):
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleShortVersionString": version,
                    "CFBundleVersion": str(build),
                },
                handle,
            )

    def write_fake_git(self, root, log, *, tag, local_tag, remote_tag):
        git_bin = root / "fake-git"
        self.write_executable(
            git_bin,
            textwrap.dedent(
                f"""\
                #!/usr/bin/env bash
                set -euo pipefail
                echo "git $*" >> {log}
                case "$1 $2" in
                  "rev-parse --show-toplevel") echo {root}; exit 0 ;;
                  "rev-parse HEAD") echo {HEAD}; exit 0 ;;
                  "rev-parse --verify")
                    if [[ "{local_tag}" == "missing" ]]; then exit 1; fi
                    echo {local_tag}; exit 0 ;;
                  "ls-remote --tags")
                    if [[ "{remote_tag}" == "missing" ]]; then exit 0; fi
                    printf '%s\\trefs/tags/{tag}\\n' {remote_tag}; exit 0 ;;
                  "tag -a") exit 0 ;;
                  "push origin") exit 0 ;;
                esac
                echo "unexpected git $*" >&2
                exit 99
                """
            ),
        )
        return git_bin

    def write_fake_gh(
        self,
        root,
        log,
        *,
        release_path,
        release_absent,
        tag,
        asset_name,
        download_source,
        download_fail,
    ):
        gh_bin = root / "fake-gh"
        absent = "1" if release_absent else "0"
        fail_download = "1" if download_fail else "0"
        self.write_executable(
            gh_bin,
            textwrap.dedent(
                f"""\
                #!/usr/bin/env bash
                set -euo pipefail
                echo "gh $*" >> {log}
                case "$1 $2" in
                  "release view")
                    if [[ "{absent}" == "1" ]]; then echo "release not found" >&2; exit 1; fi
                    cat {release_path}; exit 0 ;;
                  "release create") exit 0 ;;
                  "release upload") exit 0 ;;
                  "release download")
                    requested_tag="${{3:-}}"
                    shift 3
                    pattern=""
                    output_dir=""
                    while [[ $# -gt 0 ]]; do
                      case "$1" in
                        --pattern|-p)
                          pattern="${{2:-}}"
                          shift 2 ;;
                        --dir|-D)
                          output_dir="${{2:-}}"
                          shift 2 ;;
                        *)
                          shift ;;
                      esac
                    done
                    if [[ "$requested_tag" != "{tag}" || "$pattern" != "{asset_name}" || -z "$output_dir" ]]; then
                      echo "unexpected gh release download" >&2
                      exit 99
                    fi
                    if [[ "{fail_download}" == "1" ]]; then
                      echo "download failed" >&2
                      exit 1
                    fi
                    mkdir -p "$output_dir"
                    cp {download_source} "$output_dir/$pattern"
                    exit 0 ;;
                esac
                echo "unexpected gh $*" >&2
                exit 99
                """
            ),
        )
        return gh_bin

    def make_app_workspace(
        self,
        *,
        tag,
        dmg_name,
        title,
        changelog_path,
        changelog_text,
        release_body,
        dmg_bytes,
        release_json=None,
        release_absent=False,
        local_tag=HEAD,
        remote_tag=HEAD,
        download_bytes=None,
        download_fail=False,
    ):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = pathlib.Path(tmp.name)
        log = root / "calls.log"
        dmg = root / dmg_name
        dmg.write_bytes(dmg_bytes)
        changelog = root / changelog_path
        changelog.parent.mkdir(parents=True, exist_ok=True)
        changelog.write_text(changelog_text, encoding="utf-8")
        download_source = root / "download-asset.bin"
        download_source.write_bytes(dmg_bytes if download_bytes is None else download_bytes)

        git_bin = self.write_fake_git(root, log, tag=tag, local_tag=local_tag, remote_tag=remote_tag)
        if release_json is None:
            release_json = {
                "tagName": tag,
                "name": title,
                "body": release_body,
                "assets": [{"name": dmg.name, "size": dmg.stat().st_size}],
            }
        release_path = root / "release.json"
        release_path.write_text(json.dumps(release_json), encoding="utf-8")
        gh_bin = self.write_fake_gh(
            root,
            log,
            release_path=release_path,
            release_absent=release_absent,
            tag=tag,
            asset_name=dmg.name,
            download_source=download_source,
            download_fail=download_fail,
        )
        return root, log, git_bin, gh_bin

    def make_workspace(
        self,
        *,
        release_json=None,
        release_absent=False,
        local_tag=HEAD,
        remote_tag=HEAD,
        download_bytes=None,
        download_fail=False,
    ):
        tag = "journal-v1.0.12-build-14"
        root, log, git_bin, gh_bin = self.make_app_workspace(
            tag=tag,
            dmg_name="journal-1.0.12-build-14.dmg",
            title="journal 1.0.12 (build 14)",
            changelog_path="CHANGELOG-journal.md",
            changelog_text=(
                "# journal\n\n"
                "## [1.0.12 (build 14)] - 2026-07-22\n\n"
                "### Fixed\n"
                "- build 14\n"
            ),
            release_body="## [1.0.12 (build 14)] - 2026-07-22\n\n### Fixed\n- build 14\n",
            dmg_bytes=b"fake journal dmg",
            release_json=release_json,
            release_absent=release_absent,
            local_tag=local_tag,
            remote_tag=remote_tag,
            download_bytes=download_bytes,
            download_fail=download_fail,
        )
        self.write_plist(root / "Sources/journal/Info.plist", "1.0.12", 14)
        (root / "Makefile").write_text("SOLSTONE_PIN_VERSION ?= 1.0.12\n", encoding="utf-8")
        bundle = root / "Sources/JournalRuntime/BundleConfig.swift"
        bundle.parent.mkdir(parents=True, exist_ok=True)
        bundle.write_text(
            'public enum BundleConfig {\n'
            '    public static let solstonePinVersion = "1.0.12"\n'
            '}\n',
            encoding="utf-8",
        )

        return root, log, git_bin, gh_bin

    def make_sol_workspace(self, *, release_json=None, local_tag=HEAD, remote_tag=HEAD):
        return self.make_app_workspace(
            tag="v1.2.3",
            dmg_name="sol-1.2.3.dmg",
            title="solstone-macos 1.2.3",
            changelog_path="CHANGELOG.md",
            changelog_text=(
                "# solstone\n\n"
                "## [1.2.3] - 2026-07-22\n\n"
                "### Fixed\n"
                "- sol recovery\n"
            ),
            release_body="## [1.2.3] - 2026-07-22\n\n### Fixed\n- sol recovery\n",
            dmg_bytes=b"fake sol dmg",
            release_json=release_json,
            local_tag=local_tag,
            remote_tag=remote_tag,
        )

    def run_live(self, root, git_bin, gh_bin, *args):
        env = os.environ.copy()
        env.update(
            {
                "GIT_BIN": str(git_bin),
                "GH_BIN": str(gh_bin),
                "RELEASE_IDENTITY_BIN": str(IDENTITY),
                "EXTRACT_CHANGELOG_BIN": str(EXTRACT),
            }
        )
        release_args = args or ("--app", "journal", "--build", "14", "1.0.12")
        return subprocess.run(
            ["bash", str(SCRIPT), *release_args],
            cwd=REPO_ROOT,
            env=env,
            capture_output=True,
            text=True,
        )

    def assert_no_release_mutation(self, calls):
        self.assertNotIn("gh release upload", calls)
        self.assertNotIn("gh release create", calls)
        self.assertNotIn("gh release delete", calls)
        self.assertNotIn("--clobber", calls)

    def test_correct_tag_release_absent_creates_only_release(self):
        root, log, git_bin, gh_bin = self.make_workspace(release_absent=True)

        proc = self.run_live(root, git_bin, gh_bin)

        self.assertEqual(proc.returncode, 0, proc.stderr)
        calls = log.read_text(encoding="utf-8")
        self.assertNotIn("git tag -a", calls)
        self.assertNotIn("git push", calls)
        self.assertIn("gh release create", calls)
        self.assertNotIn("gh release upload", calls)

    def test_missing_tag_and_release_creates_tag_push_and_release(self):
        root, log, git_bin, gh_bin = self.make_workspace(
            release_absent=True, local_tag="missing", remote_tag="missing"
        )

        proc = self.run_live(root, git_bin, gh_bin)

        self.assertEqual(proc.returncode, 0, proc.stderr)
        calls = log.read_text(encoding="utf-8")
        self.assertIn("git tag -a", calls)
        self.assertIn("git push origin", calls)
        self.assertIn("gh release create", calls)

    def test_incomplete_release_uploads_only_missing_asset(self):
        release_json = {
            "tagName": "journal-v1.0.12-build-14",
            "name": "journal 1.0.12 (build 14)",
            "body": "## [1.0.12 (build 14)] - 2026-07-22\n\n### Fixed\n- build 14\n",
            "assets": [],
        }
        root, log, git_bin, gh_bin = self.make_workspace(release_json=release_json)

        proc = self.run_live(root, git_bin, gh_bin)

        self.assertEqual(proc.returncode, 0, proc.stderr)
        calls = log.read_text(encoding="utf-8")
        self.assertIn("gh release upload", calls)
        self.assertNotIn("gh release create", calls)
        self.assertNotIn("--clobber", calls)

    def test_matching_journal_asset_downloads_and_verifies_sha(self):
        root, log, git_bin, gh_bin = self.make_workspace()

        proc = self.run_live(root, git_bin, gh_bin)

        self.assertEqual(proc.returncode, 0, proc.stderr)
        calls = log.read_text(encoding="utf-8")
        self.assertIn("gh release download", calls)
        self.assertIn(EXPECTED_DMG_SHA256, proc.stdout)
        self.assert_no_release_mutation(calls)

    def test_same_length_journal_asset_sha_conflict_fails_without_mutation(self):
        root, log, git_bin, gh_bin = self.make_workspace(download_bytes=b"fake journal DMG")

        proc = self.run_live(root, git_bin, gh_bin)

        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("byte-identity conflict", proc.stderr)
        self.assertIn("SHA-256", proc.stderr)
        self.assertIn("no asset was changed", proc.stderr)
        calls = log.read_text(encoding="utf-8")
        self.assertIn("gh release download", calls)
        self.assert_no_release_mutation(calls)

    def test_journal_download_failure_is_unprovable_without_mutation(self):
        root, log, git_bin, gh_bin = self.make_workspace(download_fail=True)

        proc = self.run_live(root, git_bin, gh_bin)

        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("identity could not be proven", proc.stderr)
        self.assertIn("investigate", proc.stderr)
        calls = log.read_text(encoding="utf-8")
        self.assertIn("gh release download", calls)
        self.assert_no_release_mutation(calls)

    def test_short_journal_download_is_unprovable_without_mutation(self):
        root, log, git_bin, gh_bin = self.make_workspace(download_bytes=b"short")

        proc = self.run_live(root, git_bin, gh_bin)

        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("identity could not be proven", proc.stderr)
        self.assertIn("investigate", proc.stderr)
        calls = log.read_text(encoding="utf-8")
        self.assertIn("gh release download", calls)
        self.assert_no_release_mutation(calls)

    def test_unreadable_local_journal_dmg_is_unprovable_without_mutation(self):
        root, log, git_bin, gh_bin = self.make_workspace()
        dmg = root / "journal-1.0.12-build-14.dmg"
        dmg.chmod(0)
        self.addCleanup(lambda: dmg.chmod(0o644) if dmg.exists() else None)

        proc = self.run_live(root, git_bin, gh_bin)

        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("identity could not be proven", proc.stderr)
        self.assertIn("investigate", proc.stderr)
        calls = log.read_text(encoding="utf-8")
        self.assertIn("gh release download", calls)
        self.assert_no_release_mutation(calls)

    def test_live_sol_recovery_stays_size_only_without_download(self):
        root, log, git_bin, gh_bin = self.make_sol_workspace()

        proc = self.run_live(root, git_bin, gh_bin, "--app", "sol", "1.2.3")

        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("already matches", proc.stdout)
        calls = log.read_text(encoding="utf-8")
        self.assertNotIn("gh release download", calls)
        self.assert_no_release_mutation(calls)

    def test_wrong_commit_tag_fails_without_mutation(self):
        root, log, git_bin, gh_bin = self.make_workspace(local_tag=OTHER)

        proc = self.run_live(root, git_bin, gh_bin)

        self.assertNotEqual(proc.returncode, 0)
        calls = log.read_text(encoding="utf-8")
        self.assertNotIn("git tag -a", calls)
        self.assertNotIn("git push", calls)
        self.assertNotIn("gh release", calls)

    def test_conflicting_release_metadata_fails_without_mutation(self):
        release_json = {
            "tagName": "journal-v1.0.12-build-14",
            "name": "wrong title",
            "body": "## [1.0.12 (build 14)] - 2026-07-22\n\n### Fixed\n- build 14\n",
            "assets": [],
        }
        root, log, git_bin, gh_bin = self.make_workspace(release_json=release_json)

        proc = self.run_live(root, git_bin, gh_bin)

        self.assertNotEqual(proc.returncode, 0)
        calls = log.read_text(encoding="utf-8")
        self.assertNotIn("gh release create", calls)
        self.assertNotIn("gh release upload", calls)

    def test_unprovable_same_name_asset_fails_without_clobber(self):
        release_json = {
            "tagName": "journal-v1.0.12-build-14",
            "name": "journal 1.0.12 (build 14)",
            "body": "## [1.0.12 (build 14)] - 2026-07-22\n\n### Fixed\n- build 14\n",
            "assets": [{"name": "journal-1.0.12-build-14.dmg", "size": 999}],
        }
        root, log, git_bin, gh_bin = self.make_workspace(release_json=release_json)

        proc = self.run_live(root, git_bin, gh_bin)

        self.assertNotEqual(proc.returncode, 0)
        calls = log.read_text(encoding="utf-8")
        self.assertNotIn("gh release create", calls)
        self.assertNotIn("gh release upload", calls)
        self.assertNotIn("--clobber", calls)

    def test_pin_gate_fails_before_mutating_git_or_gh_calls(self):
        root, log, git_bin, gh_bin = self.make_workspace()
        (root / "Makefile").write_text("SOLSTONE_PIN_VERSION ?= 0.9.1\n", encoding="utf-8")

        proc = self.run_live(root, git_bin, gh_bin)

        self.assertNotEqual(proc.returncode, 0)
        calls = log.read_text(encoding="utf-8")
        self.assertNotIn("git tag -a", calls)
        self.assertNotIn("git push", calls)
        self.assertNotIn("gh release", calls)


if __name__ == "__main__":
    unittest.main()
