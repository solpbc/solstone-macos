#!/usr/bin/env python3
import hashlib
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


def verify_wheelhouse(dir_path, pin):
    wheelhouse_dir = pathlib.Path(dir_path)
    manifest = wheelhouse_dir / "MANIFEST.sha256"
    if not manifest.is_file():
        raise ValueError(f"bundled wheelhouse manifest missing at {manifest} — run make vendor-wheelhouse")

    for line in manifest.read_text().splitlines():
        if not line:
            continue
        if (
            len(line) <= 66
            or line[64:66] != "  "
            or any(char not in "0123456789abcdefABCDEF" for char in line[:64])
        ):
            raise ValueError("wheelhouse sha256 manifest verification failed")

        expected_hash = line[:64].lower()
        filename = line[66:]
        listed_file = wheelhouse_dir / filename
        if not listed_file.is_file():
            raise ValueError("wheelhouse sha256 manifest verification failed")

        actual_hash = hashlib.sha256(listed_file.read_bytes()).hexdigest()
        if actual_hash != expected_hash:
            raise ValueError("wheelhouse sha256 manifest verification failed")

    pinned_wheels = sorted(
        path
        for path in wheelhouse_dir.glob(f"solstone-{pin}-*.whl")
        if path.is_file()
    )
    if len(pinned_wheels) != 1:
        raise ValueError(f"expected exactly one solstone-{pin}-*.whl in {dir_path}")

    version = wheel_version(pinned_wheels[0])
    if version != pin:
        raise ValueError(f"sibling backend version {version} != pinned {pin} — re-pin or update sibling")

    runtime_dir_names = {"__pycache__", ".venv", "venv", "cache", "model", "models"}
    offending_paths = sorted(
        str(path)
        for path in wheelhouse_dir.rglob("*")
        if path.is_dir() and path.name in runtime_dir_names
    )
    if offending_paths:
        raise ValueError("wheelhouse contains runtime/cache/model dirs\n" + "\n".join(offending_paths))

    return len([path for path in wheelhouse_dir.glob("*.whl") if path.is_file()])


def main(argv):
    usage = "error: usage: wheelhouse_helper.py {wheel-version <wheel> | verify-wheelhouse <dir> <pin>}"
    if len(argv) < 2:
        print(usage, file=sys.stderr)
        return 1

    if argv[1] == "wheel-version":
        if len(argv) != 3:
            print(usage, file=sys.stderr)
            return 1

        try:
            print(wheel_version(argv[2]))
        except ValueError as error:
            print(f"error: {error}", file=sys.stderr)
            return 1

        return 0

    if argv[1] == "verify-wheelhouse":
        if len(argv) != 4:
            print(usage, file=sys.stderr)
            return 1

        try:
            wheel_count = verify_wheelhouse(argv[2], argv[3])
        except ValueError as error:
            print(f"error: {error}", file=sys.stderr)
            return 1

        print(f"wheelhouse: {argv[2]} verified (solstone {argv[3]}, {wheel_count} wheels)")
        return 0

    print(usage, file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
