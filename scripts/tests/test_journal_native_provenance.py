import hashlib
import io
import json
import pathlib
import plistlib
import subprocess
import tarfile
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts/journal_native_provenance.py"
MAKEFILE = REPO_ROOT / "Makefile"


class JournalNativeProvenanceTest(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="journal-native-provenance-",
            dir="/var/tmp",
        )
        self.root = pathlib.Path(self.temporary_directory.name)
        self.fixture_index = 0
        self.source = self.root / "journal"
        self.source.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=self.source, check=True)
        subprocess.run(
            ["git", "config", "user.email", "test@solstone.invalid"],
            cwd=self.source,
            check=True,
        )
        subprocess.run(
            ["git", "config", "user.name", "Test"], cwd=self.source, check=True
        )
        (self.source / "tracked.txt").write_text("accepted\n", encoding="utf-8")
        subprocess.run(["git", "add", "tracked.txt"], cwd=self.source, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "accepted"], cwd=self.source, check=True)
        self.commit = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=self.source,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

        self.output = self.root / "output"
        self.runtime = self.root / "runtime"
        (self.runtime / "bin").mkdir(parents=True)
        self.output.mkdir()
        (self.output / "journal-macos-arm64.tar.gz").write_bytes(b"archive")
        (self.runtime / "bin/journal").write_bytes(b"journal")
        (self.runtime / "bin/solstone").write_bytes(b"solstone")
        (self.runtime / "bin/journal").chmod(0o755)
        (self.runtime / "bin/solstone").chmod(0o755)
        self.receipt = self.runtime / "journal-native-provenance.json"

    def tearDown(self):
        self.temporary_directory.cleanup()

    def run_script(self, *args):
        return subprocess.run(
            ["python3", str(SCRIPT), *args],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )

    def candidate_fixture(self):
        self.fixture_index += 1
        fixture_root = self.root / f"candidate-fixture-{self.fixture_index}"
        fixture_root.mkdir()
        payload = fixture_root / "candidate-payload"
        (payload / "bin").mkdir(parents=True)
        for name, contents in (("journal", b"candidate-journal"), ("solstone", b"candidate-solstone")):
            path = payload / "bin" / name
            path.write_bytes(contents)
            path.chmod(0o755)

        accepted = fixture_root / "accepted"
        accepted.mkdir()
        archive = accepted / "solstone-journal-2.0.0-macos-arm64.tar.gz"
        with tarfile.open(archive, "w:gz") as bundle:
            bundle.add(payload / "bin", arcname="bin")
        archive_sha256 = hashlib.sha256(archive.read_bytes()).hexdigest()

        runtime = fixture_root / "candidate-runtime"
        native_receipt = runtime / "journal-native-provenance.json"
        staged = self.run_script(
            "stage-accepted",
            "--archive",
            str(archive),
            "--expected-sha256",
            archive_sha256,
            "--expected-commit",
            self.commit,
            "--acceptance-evidence",
            "journal-lane/accepted.md",
            "--target",
            "macos-arm64",
            "--workspace-root",
            str(self.root),
            "--runtime-dir",
            str(runtime),
            "--receipt",
            str(native_receipt),
        )
        self.assertEqual(staged.returncode, 0, staged.stdout + staged.stderr)

        release = accepted / "solstone-journal-2.0.0-macos-arm64.release"
        release.write_text(
            "\n".join(
                [
                    "product=solstone-journal",
                    "version=2.0.0",
                    "target=macos-arm64",
                    f"commit={self.commit}",
                    "receipt=fixture",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        signing = accepted / "solstone-journal-2.0.0-macos-arm64.signing.json"
        signing.write_text(
            json.dumps(
                {
                    "members": [
                        {
                            "path": f"bin/{name}",
                            "sha256": hashlib.sha256(contents).hexdigest(),
                        }
                        for name, contents in (
                            ("journal", b"candidate-journal"),
                            ("solstone", b"candidate-solstone"),
                        )
                    ]
                }
            )
            + "\n",
            encoding="utf-8",
        )
        manifest = accepted / "solstone-journal-2.0.0-macos-arm64.manifest.json"
        manifest.write_text(
            json.dumps(
                {
                    "product": "solstone-journal",
                    "version": "2.0.0",
                    "target": "macos-arm64",
                    "files": {
                        archive.name: archive_sha256,
                        release.name: hashlib.sha256(release.read_bytes()).hexdigest(),
                        signing.name: hashlib.sha256(signing.read_bytes()).hexdigest(),
                    },
                }
            )
            + "\n",
            encoding="utf-8",
        )
        signature = accepted / f"{manifest.name}.minisig"
        signature.write_text("test signature\n", encoding="utf-8")
        minisign = fixture_root / "minisign"
        minisign.write_text(
            "#!/bin/sh\n"
            "test \"$1\" = -Vm || exit 91\n"
            "test \"$3\" = -x || exit 92\n"
            "test \"$5\" = -P || exit 93\n"
            "test \"$6\" = RWRE2eBJv3NAtN0mF5+kqygYyP/ocYNw1Ng9yJhAKgyTflNV9NabMMjq || exit 94\n",
            encoding="utf-8",
        )
        minisign.chmod(0o755)

        info = fixture_root / "Info.plist"
        with info.open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleIdentifier": "app.solstone.journal",
                    "CFBundleShortVersionString": "2.0.0",
                    "CFBundleVersion": "30",
                },
                handle,
            )
        output = fixture_root / "Resources" / "runtime-entry-candidate-provenance.json"
        output.parent.mkdir()
        placeholder = {
            "schema": "journal-runtime-entry-candidate-provenance",
            "schema_version": 1,
            "source": "J",
            "target": {
                "bundle_identifier": "app.solstone.journal",
                "bundle_short_version": "2.0.0",
                "bundle_version": "30",
            },
            "runtime_archive_sha256": "0" * 64,
            "manifest_sha256": "1" * 64,
            "release_receipt_sha256": "2" * 64,
            "signing_receipt_sha256": "3" * 64,
            "runtime_tree_sha256": "4" * 64,
        }
        output.write_text(json.dumps(placeholder) + "\n", encoding="utf-8")
        tree_map = fixture_root / "candidate-runtime-tree.map"
        arguments = [
            "--archive",
            str(archive),
            "--expected-sha256",
            archive_sha256,
            "--expected-commit",
            self.commit,
            "--target",
            "macos-arm64",
            "--manifest",
            str(manifest),
            "--manifest-signature",
            str(signature),
            "--release-receipt",
            str(release),
            "--signing-receipt",
            str(signing),
            "--minisign",
            str(minisign),
            "--runtime-dir",
            str(runtime),
            "--native-receipt",
            str(native_receipt),
            "--info-plist",
            str(info),
            "--output",
            str(output),
            "--tree-map",
            str(tree_map),
        ]
        return {
            "arguments": arguments,
            "archive": archive,
            "archive_sha256": archive_sha256,
            "manifest": manifest,
            "release": release,
            "signing": signing,
            "runtime": runtime,
            "output": output,
            "placeholder": placeholder,
            "tree_map": tree_map,
            "minisign": minisign,
        }

    def test_check_source_requires_exact_clean_commit(self):
        valid = self.run_script(
            "check-source",
            "--source-dir",
            str(self.source),
            "--expected-commit",
            self.commit,
        )
        self.assertEqual(valid.returncode, 0, valid.stdout + valid.stderr)

        wrong = self.run_script(
            "check-source",
            "--source-dir",
            str(self.source),
            "--expected-commit",
            "0" * 40,
        )
        self.assertNotEqual(wrong.returncode, 0)

        (self.source / "untracked.txt").write_text("dirty\n", encoding="utf-8")
        dirty = self.run_script(
            "check-source",
            "--source-dir",
            str(self.source),
            "--expected-commit",
            self.commit,
        )
        self.assertNotEqual(dirty.returncode, 0)
        self.assertIn("source is dirty", dirty.stderr)

    def test_receipt_binds_source_archive_and_runtime_entries(self):
        result = self.run_script(
            "write-receipt",
            "--source-dir",
            str(self.source),
            "--expected-commit",
            self.commit,
            "--target",
            "macos-arm64",
            "--output-dir",
            str(self.output),
            "--runtime-dir",
            str(self.runtime),
            "--receipt",
            str(self.receipt),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        receipt = json.loads(self.receipt.read_text(encoding="utf-8"))
        self.assertEqual(receipt["schema"], 1)
        self.assertEqual(receipt["source"]["commit"], self.commit)
        self.assertTrue(receipt["source"]["clean"])
        self.assertEqual(receipt["target"], "macos-arm64")
        self.assertEqual(
            receipt["archive"]["sha256"], hashlib.sha256(b"archive").hexdigest()
        )
        self.assertEqual(
            receipt["entries"]["journal"]["sha256"],
            hashlib.sha256(b"journal").hexdigest(),
        )
        self.assertEqual(
            receipt["entries"]["solstone"]["sha256"],
            hashlib.sha256(b"solstone").hexdigest(),
        )

    def test_makefile_requires_commit_and_embeds_receipt_with_runtime(self):
        text = MAKEFILE.read_text(encoding="utf-8")
        self.assertIn("JOURNAL_NATIVE_EXPECTED_COMMIT ?=", text)
        self.assertIn(
            "JOURNAL_NATIVE_PROVENANCE_RECEIPT ?= "
            "$(JOURNAL_NATIVE_RUNTIME_DIR)/journal-native-provenance.json",
            text,
        )
        self.assertEqual(
            text.count("--expected-commit \"$(JOURNAL_NATIVE_EXPECTED_COMMIT)\""),
            6,
        )
        self.assertIn(
            'cp -R "$(JOURNAL_NATIVE_RUNTIME_DIR)" '
            "journal.app/Contents/Resources/solstone-runtime",
            text,
        )
        accepted_recipe = text.split("journal-native-runtime-accepted:", 1)[1].split(
            "\n\n", 1
        )[0]
        self.assertNotIn('rm -rf "$(JOURNAL_NATIVE_RUNTIME_DIR)"', accepted_recipe)
        self.assertIn('--workspace-root "$(CURDIR)"', accepted_recipe)

        bundle_recipe = text.split("bundle-dist-journal:", 1)[1].split(
            "\n\n", 1
        )[0]
        self.assertIn("write-candidate", bundle_recipe)
        self.assertIn("verify-candidate", bundle_recipe)
        self.assertLess(
            bundle_recipe.index("write-candidate"),
            bundle_recipe.index("codesign --force"),
        )
        self.assertLess(
            bundle_recipe.rindex("codesign --verify"),
            bundle_recipe.index("verify-candidate"),
        )
        for variable in (
            "JOURNAL_NATIVE_ACCEPTED_MANIFEST",
            "JOURNAL_NATIVE_ACCEPTED_MANIFEST_SIGNATURE",
            "JOURNAL_NATIVE_ACCEPTED_RELEASE_RECEIPT",
            "JOURNAL_NATIVE_ACCEPTED_SIGNING_RECEIPT",
            "JOURNAL_NATIVE_RUNTIME_TREE_MAP",
        ):
            self.assertIn(variable, bundle_recipe)

    def test_candidate_provenance_binds_exact_accepted_set_and_tree_map(self):
        fixture = self.candidate_fixture()
        placeholder_refusal = self.run_script(
            "verify-candidate", *fixture["arguments"]
        )
        self.assertNotEqual(placeholder_refusal.returncode, 0)
        self.assertIn("does not match", placeholder_refusal.stderr)

        written = self.run_script("write-candidate", *fixture["arguments"])
        self.assertEqual(written.returncode, 0, written.stdout + written.stderr)
        provenance = json.loads(fixture["output"].read_text(encoding="utf-8"))
        self.assertEqual(
            provenance["runtime_archive_sha256"], fixture["archive_sha256"]
        )
        self.assertEqual(
            provenance["manifest_sha256"],
            hashlib.sha256(fixture["manifest"].read_bytes()).hexdigest(),
        )
        self.assertEqual(
            provenance["release_receipt_sha256"],
            hashlib.sha256(fixture["release"].read_bytes()).hexdigest(),
        )
        self.assertEqual(
            provenance["signing_receipt_sha256"],
            hashlib.sha256(fixture["signing"].read_bytes()).hexdigest(),
        )
        self.assertEqual(provenance["target"]["bundle_version"], "30")
        self.assertTrue(fixture["tree_map"].is_file())
        self.assertEqual(
            provenance["runtime_tree_sha256"],
            hashlib.sha256(fixture["tree_map"].read_bytes()).hexdigest(),
        )
        for key in (
            "runtime_archive_sha256",
            "manifest_sha256",
            "release_receipt_sha256",
            "signing_receipt_sha256",
            "runtime_tree_sha256",
        ):
            self.assertNotEqual(len(set(provenance[key])), 1)

        verified = self.run_script("verify-candidate", *fixture["arguments"])
        self.assertEqual(verified.returncode, 0, verified.stdout + verified.stderr)

    def test_candidate_provenance_refuses_manifest_and_runtime_mismatches(self):
        fixture = self.candidate_fixture()
        original_output = fixture["output"].read_bytes()
        manifest = json.loads(fixture["manifest"].read_text(encoding="utf-8"))
        manifest["files"][fixture["archive"].name] = "a" * 64
        fixture["manifest"].write_text(json.dumps(manifest) + "\n", encoding="utf-8")
        manifest_refusal = self.run_script("write-candidate", *fixture["arguments"])
        self.assertNotEqual(manifest_refusal.returncode, 0)
        self.assertIn("manifest digest mismatch", manifest_refusal.stderr)
        self.assertEqual(fixture["output"].read_bytes(), original_output)

        fixture = self.candidate_fixture()
        (fixture["runtime"] / "bin/journal").write_bytes(b"substituted")
        runtime_refusal = self.run_script("write-candidate", *fixture["arguments"])
        self.assertNotEqual(runtime_refusal.returncode, 0)
        self.assertIn("differs from accepted archive", runtime_refusal.stderr)

        fixture = self.candidate_fixture()
        (fixture["runtime"] / "unlisted").write_bytes(b"extra")
        inventory_refusal = self.run_script(
            "write-candidate", *fixture["arguments"]
        )
        self.assertNotEqual(inventory_refusal.returncode, 0)
        self.assertIn("runtime file inventory mismatch", inventory_refusal.stderr)

    def test_candidate_provenance_refuses_unverified_manifest_signature(self):
        fixture = self.candidate_fixture()
        fixture["minisign"].write_text("#!/bin/sh\nexit 7\n", encoding="utf-8")
        fixture["minisign"].chmod(0o755)
        result = self.run_script("write-candidate", *fixture["arguments"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("manifest signature verification failed", result.stderr)

    def test_candidate_provenance_refuses_duplicate_json_and_target_mismatch(self):
        fixture = self.candidate_fixture()
        fixture["manifest"].write_text(
            '{"product":"solstone-journal","product":"substituted",'
            '"version":"2.0.0","target":"macos-arm64","files":{}}\n',
            encoding="utf-8",
        )
        duplicate = self.run_script("write-candidate", *fixture["arguments"])
        self.assertNotEqual(duplicate.returncode, 0)
        self.assertIn("duplicate JSON key", duplicate.stderr)

        fixture = self.candidate_fixture()
        info_path = pathlib.Path(
            fixture["arguments"][fixture["arguments"].index("--info-plist") + 1]
        )
        with info_path.open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleIdentifier": "app.solstone.journal",
                    "CFBundleShortVersionString": "2.0.1",
                    "CFBundleVersion": "30",
                },
                handle,
            )
        target = self.run_script("write-candidate", *fixture["arguments"])
        self.assertNotEqual(target.returncode, 0)
        self.assertIn("identity does not match", target.stderr)

    def test_stage_accepted_verifies_digest_and_records_handoff(self):
        archive = self.root / "accepted.tar.gz"
        with tarfile.open(archive, "w:gz") as bundle:
            bundle.add(self.runtime / "bin", arcname="bin")
        expected_sha256 = hashlib.sha256(archive.read_bytes()).hexdigest()
        staged = self.root / "staged"
        receipt = staged / "journal-native-provenance.json"

        result = self.run_script(
            "stage-accepted",
            "--archive",
            str(archive),
            "--expected-sha256",
            expected_sha256,
            "--expected-commit",
            self.commit,
            "--acceptance-evidence",
            "journal-lane/receipt.json",
            "--target",
            "macos-arm64",
            "--workspace-root",
            str(self.root),
            "--runtime-dir",
            str(staged),
            "--receipt",
            str(receipt),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        body = json.loads(receipt.read_text(encoding="utf-8"))
        self.assertEqual(body["mode"], "accepted-archive")
        self.assertEqual(body["source"]["commit"], self.commit)
        self.assertEqual(
            body["source"]["acceptance_evidence"], "journal-lane/receipt.json"
        )
        self.assertEqual(body["archive"]["sha256"], expected_sha256)

        refused_runtime = self.root / "refused"
        refused_runtime.mkdir()
        (refused_runtime / "sentinel").write_text("preserve\n", encoding="utf-8")
        refused = self.run_script(
            "stage-accepted",
            "--archive",
            str(archive),
            "--expected-sha256",
            "0" * 64,
            "--expected-commit",
            self.commit,
            "--acceptance-evidence",
            "journal-lane/receipt.json",
            "--target",
            "macos-arm64",
            "--workspace-root",
            str(self.root),
            "--runtime-dir",
            str(refused_runtime),
            "--receipt",
            str(self.root / "refused.json"),
        )
        self.assertNotEqual(refused.returncode, 0)
        self.assertEqual(
            (refused_runtime / "sentinel").read_text(encoding="utf-8"),
            "preserve\n",
        )

    def test_stage_accepted_refuses_symlinked_archive(self):
        archive = self.root / "accepted.tar.gz"
        with tarfile.open(archive, "w:gz") as bundle:
            bundle.add(self.runtime / "bin", arcname="bin")
        link = self.root / "accepted-link.tar.gz"
        link.symlink_to(archive)
        result = self.run_script(
            "stage-accepted",
            "--archive",
            str(link),
            "--expected-sha256",
            hashlib.sha256(archive.read_bytes()).hexdigest(),
            "--expected-commit",
            self.commit,
            "--acceptance-evidence",
            "journal-lane/receipt.json",
            "--target",
            "macos-arm64",
            "--workspace-root",
            str(self.root),
            "--runtime-dir",
            str(self.root / "symlink-refused"),
            "--receipt",
            str(self.root / "symlink-refused/journal-native-provenance.json"),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must not be a symlink", result.stderr)

    def test_stage_accepted_refuses_unsafe_archive_members(self):
        expected_errors = {
            "traversal": "unsafe member path",
            "symlink": "not a regular file or directory",
            "hardlink": "not a regular file or directory",
            "fifo": "not a regular file or directory",
            "device": "not a regular file or directory",
            "duplicate": "duplicate member path",
            "collision": "cannot extract accepted journal archive",
        }
        for kind, expected_error in expected_errors.items():
            with self.subTest(kind=kind):
                archive = self.root / f"unsafe-{kind}.tar.gz"
                with tarfile.open(archive, "w:gz") as bundle:
                    if kind == "traversal":
                        member = tarfile.TarInfo("../escaped")
                        member.size = 0
                        bundle.addfile(member)
                    elif kind == "symlink":
                        member = tarfile.TarInfo("bin/linked")
                        member.type = tarfile.SYMTYPE
                        member.linkname = "/tmp/escaped"
                        bundle.addfile(member)
                    elif kind == "hardlink":
                        member = tarfile.TarInfo("bin/linked")
                        member.type = tarfile.LNKTYPE
                        member.linkname = "bin/journal"
                        bundle.addfile(member)
                    elif kind == "fifo":
                        member = tarfile.TarInfo("bin/fifo")
                        member.type = tarfile.FIFOTYPE
                        bundle.addfile(member)
                    elif kind == "device":
                        member = tarfile.TarInfo("bin/device")
                        member.type = tarfile.CHRTYPE
                        member.devmajor = 1
                        member.devminor = 3
                        bundle.addfile(member)
                    elif kind == "duplicate":
                        bundle.addfile(tarfile.TarInfo("bin/duplicate"))
                        bundle.addfile(tarfile.TarInfo("bin/duplicate"))
                    else:
                        bundle.addfile(tarfile.TarInfo("bin"))
                        bundle.addfile(tarfile.TarInfo("bin/journal"))

                staged = self.root / f"unsafe-{kind}-runtime"
                staged.mkdir()
                sentinel = staged / "sentinel"
                sentinel.write_text("preserve\n", encoding="utf-8")
                result = self.run_script(
                    "stage-accepted",
                    "--archive",
                    str(archive),
                    "--expected-sha256",
                    hashlib.sha256(archive.read_bytes()).hexdigest(),
                    "--expected-commit",
                    self.commit,
                    "--acceptance-evidence",
                    "journal-lane/receipt.json",
                    "--target",
                    "macos-arm64",
                    "--workspace-root",
                    str(self.root),
                    "--runtime-dir",
                    str(staged),
                    "--receipt",
                    str(staged / "journal-native-provenance.json"),
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected_error, result.stderr)
                self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve\n")

    def test_stage_accepted_sanitizes_restrictive_modes(self):
        archive = self.root / "restrictive.tar.gz"
        with tarfile.open(archive, "w:gz") as bundle:
            directory = tarfile.TarInfo("bin")
            directory.type = tarfile.DIRTYPE
            directory.mode = 0
            bundle.addfile(directory)
            for name in ("journal", "solstone"):
                payload = name.encode("utf-8")
                member = tarfile.TarInfo(f"bin/{name}")
                member.mode = 0o555
                member.size = len(payload)
                bundle.addfile(member, io.BytesIO(payload))

        staged = self.root / "restrictive-runtime"
        result = self.run_script(
            "stage-accepted",
            "--archive",
            str(archive),
            "--expected-sha256",
            hashlib.sha256(archive.read_bytes()).hexdigest(),
            "--expected-commit",
            self.commit,
            "--acceptance-evidence",
            "journal-lane/receipt.json",
            "--target",
            "macos-arm64",
            "--workspace-root",
            str(self.root),
            "--runtime-dir",
            str(staged),
            "--receipt",
            str(staged / "journal-native-provenance.json"),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((staged / "bin/journal").stat().st_mode & 0o100)
        self.assertTrue((staged / "bin/solstone").stat().st_mode & 0o100)


if __name__ == "__main__":
    unittest.main()
