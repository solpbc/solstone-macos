#!/usr/bin/env python3
"""Codesign native binaries inside wheelhouse wheels for macOS notarization."""

import argparse
import base64
import csv
import hashlib
import io
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import zipfile


NATIVE_SUFFIXES = {".so", ".dylib", ".bundle"}
DEFAULT_IDENTIFIER = "app.solstone.observer.wheelhouse"


def is_native_payload(path: pathlib.Path) -> bool:
    return path.suffix in NATIVE_SUFFIXES


def record_digest(path: pathlib.Path) -> tuple[str, str]:
    payload = path.read_bytes()
    digest = base64.urlsafe_b64encode(hashlib.sha256(payload).digest()).rstrip(b"=").decode("ascii")
    return f"sha256={digest}", str(len(payload))


def find_record(root: pathlib.Path) -> pathlib.Path:
    records = sorted(root.glob("*.dist-info/RECORD"))
    if len(records) != 1:
        raise ValueError(f"expected exactly one .dist-info/RECORD, found {len(records)}")
    return records[0]


def rewrite_record(root: pathlib.Path) -> None:
    record = find_record(root)
    rows = []
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        rel = path.relative_to(root).as_posix()
        if path == record:
            rows.append([rel, "", ""])
        else:
            digest, size = record_digest(path)
            rows.append([rel, digest, size])

    buffer = io.StringIO()
    writer = csv.writer(buffer, lineterminator="\n")
    writer.writerows(rows)
    record.write_text(buffer.getvalue(), encoding="utf-8")


def run_codesign(path: pathlib.Path, args: argparse.Namespace) -> None:
    command = [
        args.codesign,
        "--force",
        "--options",
        "runtime",
        "--timestamp",
        "--identifier",
        args.identifier,
        "--sign",
        args.identity,
    ]
    if args.keychain:
        command.extend(["--keychain", args.keychain])
    command.append(str(path))
    subprocess.run(command, check=True)


def repack_wheel(source: pathlib.Path, root: pathlib.Path, original_infos: dict[str, zipfile.ZipInfo]) -> None:
    temp_wheel = source.with_suffix(source.suffix + ".tmp")
    try:
        with zipfile.ZipFile(temp_wheel, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(p for p in root.rglob("*") if p.is_file()):
                rel = path.relative_to(root).as_posix()
                original = original_infos.get(rel)
                info = zipfile.ZipInfo(rel)
                info.compress_type = zipfile.ZIP_DEFLATED
                if original is not None:
                    info.date_time = original.date_time
                    info.external_attr = original.external_attr
                    info.comment = original.comment
                else:
                    info.external_attr = (0o644 & 0xFFFF) << 16
                archive.writestr(info, path.read_bytes())
        os.replace(temp_wheel, source)
    finally:
        temp_wheel.unlink(missing_ok=True)


def sign_wheel(path: pathlib.Path, args: argparse.Namespace) -> int:
    with tempfile.TemporaryDirectory(prefix=f"{path.stem}.") as tmp:
        root = pathlib.Path(tmp) / "wheel"
        root.mkdir()
        with zipfile.ZipFile(path) as archive:
            original_infos = {info.filename: info for info in archive.infolist()}
            archive.extractall(root)

        native_payloads = sorted(p for p in root.rglob("*") if p.is_file() and is_native_payload(p))
        if not native_payloads:
            return 0

        for payload in native_payloads:
            run_codesign(payload, args)

        rewrite_record(root)
        repack_wheel(path, root, original_infos)
        return len(native_payloads)


def regenerate_manifest(wheelhouse: pathlib.Path) -> None:
    manifest = wheelhouse / "MANIFEST.sha256"
    with manifest.open("w", encoding="utf-8") as output:
        for wheel in sorted(wheelhouse.glob("*.whl")):
            digest = hashlib.sha256(wheel.read_bytes()).hexdigest()
            output.write(f"{digest}  {wheel.name}\n")


def sign_wheelhouse(wheelhouse: pathlib.Path, args: argparse.Namespace) -> tuple[int, int]:
    if not wheelhouse.is_dir():
        raise ValueError(f"wheelhouse not found: {wheelhouse}")

    signed_wheels = 0
    signed_payloads = 0
    for wheel in sorted(wheelhouse.glob("*.whl")):
        count = sign_wheel(wheel, args)
        if count:
            signed_wheels += 1
            signed_payloads += count

    regenerate_manifest(wheelhouse)
    return signed_wheels, signed_payloads


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wheelhouse", help="directory containing .whl files and MANIFEST.sha256")
    parser.add_argument("--identity", required=True, help="codesign identity")
    parser.add_argument("--keychain", default="", help="codesign keychain path")
    parser.add_argument("--identifier", default=DEFAULT_IDENTIFIER, help="codesign identifier for native wheel payloads")
    parser.add_argument("--codesign", default=shutil.which("codesign") or "codesign", help="codesign executable")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        wheels, payloads = sign_wheelhouse(pathlib.Path(args.wheelhouse), args)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print(f"wheelhouse native signing: {payloads} payloads in {wheels} wheels")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
