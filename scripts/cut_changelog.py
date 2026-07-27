#!/usr/bin/env python3
"""Cut the staged Unreleased notes into a dated release section."""
from __future__ import annotations

import argparse
import os
import re
import stat
import sys
import tempfile
from datetime import date
from pathlib import Path


SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$")
UNRELEASED_HEADING = b"## [Unreleased]"


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def validate(lines: list[bytes], version: str, path: Path) -> int:
    if not SEMVER.fullmatch(version):
        fail(f"VERSION must be semver, got {version!r}")

    headings = [
        index
        for index, line in enumerate(lines)
        if line.rstrip(b"\r\n") == UNRELEASED_HEADING
    ]
    if len(headings) != 1:
        fail(
            f"{path} must contain exactly one '## [Unreleased]' heading; "
            f"found {len(headings)}"
        )

    release_headings = [
        index
        for index, line in enumerate(lines)
        if line.rstrip(b"\r\n").startswith(b"## [")
    ]
    if not release_headings or headings[0] != release_headings[0]:
        fail(f"{path} must have '## [Unreleased]' as its first release heading")

    target = re.compile(
        rb"^## \[" + re.escape(version.encode("utf-8")) + rb"\](?:\s|$)"
    )
    if any(target.match(line.rstrip(b"\r\n")) for line in lines):
        fail(f"{path} already contains a [{version}] release section")

    next_heading = next(
        (index for index in release_headings if index > headings[0]),
        len(lines),
    )
    staged_lines = lines[headings[0] + 1 : next_heading]
    if not any(line.lstrip().startswith(b"- ") for line in staged_lines):
        fail(f"{path} has no staged release-note bullets under '## [Unreleased]'")

    return headings[0]


def cut(path: Path, version: str, release_date: str, check_only: bool) -> None:
    try:
        date.fromisoformat(release_date)
    except ValueError:
        fail(f"DATE must be YYYY-MM-DD, got {release_date!r}")

    original = path.read_bytes()
    lines = original.splitlines(keepends=True)
    unreleased_index = validate(lines, version, path)
    if check_only:
        return

    heading_line = lines[unreleased_index]
    newline = b"\r\n" if heading_line.endswith(b"\r\n") else b"\n"
    release_heading = f"## [{version}] - {release_date}".encode("utf-8")
    lines[unreleased_index : unreleased_index + 1] = [
        heading_line,
        newline,
        release_heading + newline,
    ]
    updated = b"".join(lines)

    mode = stat.S_IMODE(path.stat().st_mode)
    temporary_name = ""
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as temporary:
            temporary.write(updated)
            temporary_name = temporary.name
        os.chmod(temporary_name, mode)
        os.replace(temporary_name, path)
    finally:
        if temporary_name and os.path.exists(temporary_name):
            os.unlink(temporary_name)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Turn the single Unreleased changelog section into a dated release."
    )
    parser.add_argument("path", type=Path)
    parser.add_argument("version")
    parser.add_argument("--date", default=date.today().isoformat())
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()

    cut(args.path, args.version, args.date, args.check_only)


if __name__ == "__main__":
    main()
