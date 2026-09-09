import hashlib
import json
import pathlib
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
            4,
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


if __name__ == "__main__":
    unittest.main()
