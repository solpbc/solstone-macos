import hashlib
import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import unittest
import zipfile


def load_wheelhouse_helper():
    path = pathlib.Path(__file__).resolve().parents[1] / "wheelhouse_helper.py"
    spec = importlib.util.spec_from_file_location("wheelhouse_helper", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def make_wheel(root, name="sample-1.2.3-py3-none-any.whl", metadata=None):
    wheel = pathlib.Path(root) / name
    with zipfile.ZipFile(wheel, "w") as archive:
        if metadata is not None:
            for path, content in metadata:
                archive.writestr(path, content)
        else:
            archive.writestr(
                "sample-1.2.3.dist-info/METADATA",
                "Metadata-Version: 2.4\nName: sample\nVersion: 1.2.3\n",
            )
    return wheel


def write_wheelhouse_manifest(root):
    manifest = pathlib.Path(root) / "MANIFEST.sha256"
    with manifest.open("w") as manifest_file:
        for wheel in sorted(pathlib.Path(root).glob("*.whl")):
            digest = hashlib.sha256(wheel.read_bytes()).hexdigest()
            manifest_file.write(f"{digest}  {wheel.name}\n")
    return manifest


def make_wheelhouse(root, pin="0.4.8", solstone_version=None):
    solstone_version = solstone_version or pin
    make_wheel(
        root,
        name=f"solstone-{pin}-py3-none-any.whl",
        metadata=[
            (
                f"solstone-{solstone_version}.dist-info/METADATA",
                f"Metadata-Version: 2.4\nName: solstone\nVersion: {solstone_version}\n",
            ),
        ],
    )
    make_wheel(
        root,
        name="dep-1.0.0-py3-none-any.whl",
        metadata=[
            (
                "dep-1.0.0.dist-info/METADATA",
                "Metadata-Version: 2.4\nName: dep\nVersion: 1.0.0\n",
            ),
        ],
    )
    write_wheelhouse_manifest(root)


class WheelVersionTest(unittest.TestCase):
    def test_wheel_version_reads_metadata_version(self):
        module = load_wheelhouse_helper()
        with tempfile.TemporaryDirectory() as tmp:
            wheel = make_wheel(tmp)

            self.assertEqual(module.wheel_version(wheel), "1.2.3")

    def test_wheel_version_raises_when_metadata_missing(self):
        module = load_wheelhouse_helper()
        with tempfile.TemporaryDirectory() as tmp:
            wheel = make_wheel(tmp, metadata=[])

            with self.assertRaisesRegex(ValueError, "metadata not found"):
                module.wheel_version(wheel)

    def test_wheel_version_raises_when_metadata_ambiguous(self):
        module = load_wheelhouse_helper()
        with tempfile.TemporaryDirectory() as tmp:
            wheel = make_wheel(
                tmp,
                metadata=[
                    ("sample-1.2.3.dist-info/METADATA", "Version: 1.2.3\n"),
                    ("other-1.2.3.dist-info/METADATA", "Version: 1.2.3\n"),
                ],
            )

            with self.assertRaisesRegex(ValueError, "ambiguous"):
                module.wheel_version(wheel)

    def test_wheel_version_raises_when_version_missing(self):
        module = load_wheelhouse_helper()
        with tempfile.TemporaryDirectory() as tmp:
            wheel = make_wheel(
                tmp,
                metadata=[
                    ("sample-1.2.3.dist-info/METADATA", "Metadata-Version: 2.4\nName: sample\n"),
                ],
            )

            with self.assertRaisesRegex(ValueError, "missing Version"):
                module.wheel_version(wheel)

    def test_cli_wheel_version_prints_version(self):
        helper = pathlib.Path(__file__).resolve().parents[1] / "wheelhouse_helper.py"
        with tempfile.TemporaryDirectory() as tmp:
            wheel = make_wheel(tmp)

            result = subprocess.run(
                [sys.executable, str(helper), "wheel-version", str(wheel)],
                check=False,
                text=True,
                capture_output=True,
            )

        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "1.2.3\n")
        self.assertEqual(result.stderr, "")


class VerifyWheelhouseTest(unittest.TestCase):
    def test_verify_wheelhouse_returns_wheel_count(self):
        module = load_wheelhouse_helper()
        with tempfile.TemporaryDirectory() as tmp:
            make_wheelhouse(tmp)

            self.assertEqual(module.verify_wheelhouse(tmp, "0.4.8"), 2)

    def test_verify_wheelhouse_raises_when_manifest_missing(self):
        module = load_wheelhouse_helper()
        with tempfile.TemporaryDirectory() as tmp:
            make_wheelhouse(tmp)
            (pathlib.Path(tmp) / "MANIFEST.sha256").unlink()

            with self.assertRaisesRegex(ValueError, "manifest missing at"):
                module.verify_wheelhouse(tmp, "0.4.8")

    def test_verify_wheelhouse_raises_when_zero_pinned_wheels(self):
        module = load_wheelhouse_helper()
        with tempfile.TemporaryDirectory() as tmp:
            make_wheelhouse(tmp)
            (pathlib.Path(tmp) / "solstone-0.4.8-py3-none-any.whl").unlink()
            write_wheelhouse_manifest(tmp)

            with self.assertRaisesRegex(ValueError, "expected exactly one"):
                module.verify_wheelhouse(tmp, "0.4.8")

    def test_verify_wheelhouse_raises_when_two_pinned_wheels(self):
        module = load_wheelhouse_helper()
        with tempfile.TemporaryDirectory() as tmp:
            make_wheelhouse(tmp)
            make_wheel(
                tmp,
                name="solstone-0.4.8-2-py3-none-any.whl",
                metadata=[
                    (
                        "solstone-0.4.8.dist-info/METADATA",
                        "Metadata-Version: 2.4\nName: solstone\nVersion: 0.4.8\n",
                    ),
                ],
            )
            write_wheelhouse_manifest(tmp)

            with self.assertRaisesRegex(ValueError, "expected exactly one"):
                module.verify_wheelhouse(tmp, "0.4.8")

    def test_verify_wheelhouse_raises_when_pinned_version_mismatches(self):
        module = load_wheelhouse_helper()
        with tempfile.TemporaryDirectory() as tmp:
            make_wheelhouse(tmp, pin="0.4.8", solstone_version="0.4.9")

            with self.assertRaisesRegex(ValueError, "!= pinned"):
                module.verify_wheelhouse(tmp, "0.4.8")

    def test_verify_wheelhouse_raises_when_manifest_hash_is_tampered(self):
        module = load_wheelhouse_helper()
        with tempfile.TemporaryDirectory() as tmp:
            make_wheelhouse(tmp)
            manifest = pathlib.Path(tmp) / "MANIFEST.sha256"
            text = manifest.read_text()
            replacement = "0" if text[0] != "0" else "1"
            manifest.write_text(replacement + text[1:])

            with self.assertRaisesRegex(ValueError, "manifest verification failed"):
                module.verify_wheelhouse(tmp, "0.4.8")

    def test_verify_wheelhouse_raises_when_manifest_file_is_missing(self):
        module = load_wheelhouse_helper()
        with tempfile.TemporaryDirectory() as tmp:
            make_wheelhouse(tmp)
            (pathlib.Path(tmp) / "dep-1.0.0-py3-none-any.whl").unlink()

            with self.assertRaisesRegex(ValueError, "manifest verification failed"):
                module.verify_wheelhouse(tmp, "0.4.8")

    def test_verify_wheelhouse_raises_when_runtime_dirs_exist(self):
        module = load_wheelhouse_helper()
        with tempfile.TemporaryDirectory() as tmp:
            make_wheelhouse(tmp)
            pycache = pathlib.Path(tmp) / "__pycache__"
            models = pathlib.Path(tmp) / "sub" / "models"
            pycache.mkdir()
            models.mkdir(parents=True)

            with self.assertRaisesRegex(ValueError, "runtime/cache/model dirs") as context:
                module.verify_wheelhouse(tmp, "0.4.8")

            self.assertIn(str(pycache), str(context.exception))
            self.assertIn(str(models), str(context.exception))

    def test_cli_verify_wheelhouse_prints_success(self):
        helper = pathlib.Path(__file__).resolve().parents[1] / "wheelhouse_helper.py"
        with tempfile.TemporaryDirectory() as tmp:
            make_wheelhouse(tmp)

            result = subprocess.run(
                [sys.executable, str(helper), "verify-wheelhouse", tmp, "0.4.8"],
                check=False,
                text=True,
                capture_output=True,
            )

        self.assertEqual(result.returncode, 0)
        self.assertIn("verified", result.stdout)
        self.assertEqual(result.stderr, "")

    def test_cli_verify_wheelhouse_prints_error(self):
        helper = pathlib.Path(__file__).resolve().parents[1] / "wheelhouse_helper.py"
        with tempfile.TemporaryDirectory() as tmp:
            make_wheelhouse(tmp)
            (pathlib.Path(tmp) / "MANIFEST.sha256").unlink()

            result = subprocess.run(
                [sys.executable, str(helper), "verify-wheelhouse", tmp, "0.4.8"],
                check=False,
                text=True,
                capture_output=True,
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("error:", result.stderr)


if __name__ == "__main__":
    unittest.main()
