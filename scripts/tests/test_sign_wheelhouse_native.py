import base64
import csv
import hashlib
import pathlib
import subprocess
import sys
import tempfile
import unittest
import zipfile


HELPER = pathlib.Path(__file__).resolve().parents[1] / "sign_wheelhouse_native.py"


def write_manifest(root):
    manifest = pathlib.Path(root) / "MANIFEST.sha256"
    with manifest.open("w", encoding="utf-8") as output:
        for wheel in sorted(pathlib.Path(root).glob("*.whl")):
            output.write(f"{hashlib.sha256(wheel.read_bytes()).hexdigest()}  {wheel.name}\n")


def write_record(rows):
    output = []
    for name, payload in rows:
        if name.endswith("/RECORD"):
            output.append([name, "", ""])
        else:
            digest = base64.urlsafe_b64encode(hashlib.sha256(payload).digest()).rstrip(b"=").decode("ascii")
            output.append([name, f"sha256={digest}", str(len(payload))])
    return "\n".join(",".join(row) for row in output) + "\n"


def make_wheel(root, name, rows):
    wheel = pathlib.Path(root) / name
    record_name = "sample-1.0.0.dist-info/RECORD"
    full_rows = list(rows)
    full_rows.append(("sample-1.0.0.dist-info/METADATA", b"Metadata-Version: 2.4\nName: sample\nVersion: 1.0.0\n"))
    full_rows.append((record_name, b""))
    record = write_record(full_rows).encode("utf-8")

    with zipfile.ZipFile(wheel, "w") as archive:
        for path, payload in full_rows:
            archive.writestr(path, record if path == record_name else payload)
    return wheel


def make_fake_codesign(root):
    log = pathlib.Path(root) / "codesign.log"
    script = pathlib.Path(root) / "fake-codesign.py"
    script.write_text(
        """#!/usr/bin/env python3
import pathlib
import sys
target = pathlib.Path(sys.argv[-1])
with target.open("ab") as output:
    output.write(b"\\nSIGNED\\n")
with open(sys.argv[1], "a", encoding="utf-8") as log:
    log.write(str(target) + "\\n")
""",
        encoding="utf-8",
    )
    script.chmod(0o755)
    wrapper = pathlib.Path(root) / "codesign"
    wrapper.write_text(f"#!/bin/sh\nexec {sys.executable} {script} {log} \"$@\"\n", encoding="utf-8")
    wrapper.chmod(0o755)
    return wrapper, log


def record_rows(wheel):
    with zipfile.ZipFile(wheel) as archive:
        record_name = [name for name in archive.namelist() if name.endswith(".dist-info/RECORD")][0]
        return list(csv.reader(archive.read(record_name).decode("utf-8").splitlines()))


class SignWheelhouseNativeTest(unittest.TestCase):
    def test_signs_native_payloads_rewrites_record_and_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            native_wheel = make_wheel(
                root,
                "native-1.0.0-cp313-cp313-macosx_14_0_arm64.whl",
                [("sample/module.cpython-313-darwin.so", b"mach-o-ish"), ("sample/__init__.py", b"")],
            )
            pure_wheel = make_wheel(root, "pure-1.0.0-py3-none-any.whl", [("sample/pure.py", b"ok")])
            write_manifest(root)
            old_pure = pure_wheel.read_bytes()
            fake_codesign, log = make_fake_codesign(root)

            result = subprocess.run(
                [
                    sys.executable,
                    str(HELPER),
                    str(root),
                    "--identity",
                    "Developer ID Application: test",
                    "--keychain",
                    "/tmp/test.keychain",
                    "--codesign",
                    str(fake_codesign),
                ],
                check=False,
                text=True,
                capture_output=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("1 payloads in 1 wheels", result.stdout)
            self.assertIn("module.cpython-313-darwin.so", log.read_text())
            self.assertEqual(pure_wheel.read_bytes(), old_pure)

            with zipfile.ZipFile(native_wheel) as archive:
                signed_payload = archive.read("sample/module.cpython-313-darwin.so")
            self.assertTrue(signed_payload.endswith(b"\nSIGNED\n"))

            rows = {row[0]: row for row in record_rows(native_wheel)}
            payload_row = rows["sample/module.cpython-313-darwin.so"]
            expected_digest = base64.urlsafe_b64encode(hashlib.sha256(signed_payload).digest()).rstrip(b"=").decode("ascii")
            self.assertEqual(payload_row[1], f"sha256={expected_digest}")
            self.assertEqual(payload_row[2], str(len(signed_payload)))
            record_row = rows["sample-1.0.0.dist-info/RECORD"]
            self.assertEqual(record_row[1:], ["", ""])

            manifest = (root / "MANIFEST.sha256").read_text()
            for wheel in sorted(root.glob("*.whl")):
                self.assertIn(f"{hashlib.sha256(wheel.read_bytes()).hexdigest()}  {wheel.name}", manifest)

    def test_rejects_unsafe_wheel_member_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            with zipfile.ZipFile(root / "bad-1.0.0-py3-none-any.whl", "w") as archive:
                archive.writestr("../bad.cpython-313-darwin.so", b"bad")
                archive.writestr("bad-1.0.0.dist-info/RECORD", "")
            write_manifest(root)
            fake_codesign, _log = make_fake_codesign(root)

            result = subprocess.run(
                [
                    sys.executable,
                    str(HELPER),
                    str(root),
                    "--identity",
                    "Developer ID Application: test",
                    "--codesign",
                    str(fake_codesign),
                ],
                check=False,
                text=True,
                capture_output=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unsafe wheel member path", result.stderr)


if __name__ == "__main__":
    unittest.main()
