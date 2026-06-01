#!/usr/bin/env python3
import pathlib
import sys
import zipfile


def wheel_version(path):
    wheel_path = pathlib.Path(path)
    if not wheel_path.is_file():
        raise ValueError(f"wheel not found: {wheel_path}")

    with zipfile.ZipFile(wheel_path) as wheel:
        metadata_files = [
            name
            for name in wheel.namelist()
            if name.endswith(".dist-info/METADATA")
        ]
        if not metadata_files:
            raise ValueError(f"wheel metadata not found: {wheel_path}")
        if len(metadata_files) > 1:
            raise ValueError(f"wheel metadata is ambiguous: {wheel_path}")

        metadata = wheel.read(metadata_files[0]).decode("utf-8")

    for line in metadata.splitlines():
        if line.startswith("Version:"):
            version = line.partition(":")[2].strip()
            if version:
                return version
            break

    raise ValueError(f"wheel metadata missing Version: {wheel_path}")


def main(argv):
    if len(argv) != 3 or argv[1] != "wheel-version":
        print("error: usage: wheelhouse_helper.py wheel-version <wheel>", file=sys.stderr)
        return 1

    try:
        print(wheel_version(argv[2]))
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
