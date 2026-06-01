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


if __name__ == "__main__":
    unittest.main()
