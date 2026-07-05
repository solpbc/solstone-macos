#!/usr/bin/env python3
"""Assert a signed native wheel payload uses the expected codesign identifier."""

from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile
import zipfile


NATIVE_SUFFIXES = (".so", ".dylib", ".bundle")


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: assert_wheelhouse_native_identifier.py <wheelhouse> <identifier>", file=sys.stderr)
        return 2

    wheelhouse = pathlib.Path(argv[0])
    expected = argv[1]
    if not wheelhouse.is_dir():
        print(f"error: wheelhouse not found: {wheelhouse}", file=sys.stderr)
        return 1

    for wheel in sorted(wheelhouse.glob("*.whl")):
        with zipfile.ZipFile(wheel) as archive:
            member = next(
                (name for name in archive.namelist() if name.endswith(NATIVE_SUFFIXES)),
                None,
            )
            if member is None:
                continue

            with tempfile.TemporaryDirectory(prefix="wheel-native-id.") as temp_dir:
                archive.extract(member, temp_dir)
                payload = pathlib.Path(temp_dir) / member
                result = subprocess.run(
                    ["codesign", "-dvvv", str(payload)],
                    check=False,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                )
                if result.returncode != 0:
                    sys.stderr.write(result.stdout)
                    return result.returncode
                if f"Identifier={expected}" not in result.stdout:
                    print(
                        f"error: {wheel.name}:{member} identifier is not {expected}",
                        file=sys.stderr,
                    )
                    sys.stderr.write(result.stdout)
                    return 1
                print(f"wheelhouse native identifier ok: {wheel.name}:{member}")
                return 0

    print("wheelhouse native identifier check: skipped (no native payloads)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
