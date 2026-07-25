#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc

"""Small helper for macOS user keychain search-list arithmetic."""

from __future__ import annotations

import argparse
import subprocess
import sys
from collections.abc import Sequence


SECURITY = "security"  # Intentionally bare for PATH lookup; tests shadow it.


def _parse_quoted_lines(stdout: str) -> list[str]:
    paths: list[str] = []
    for raw_line in stdout.splitlines():
        line = raw_line.lstrip(" \t")
        if not line:
            continue
        if len(line) < 2 or not line.startswith('"') or not line.endswith('"'):
            raise ValueError(f"unexpected security output line: {raw_line!r}")
        paths.append(line[1:-1])
    return paths


def parse_search_list(stdout: str) -> list[str]:
    return _parse_quoted_lines(stdout)


def parse_default_keychain(stdout: str) -> str | None:
    paths = _parse_quoted_lines(stdout)
    if not paths:
        return None
    if len(paths) > 1:
        raise ValueError("default-keychain output contained multiple entries")
    return paths[0]


def prepend_unique(paths: Sequence[str], path: str) -> list[str]:
    return [path, *(existing for existing in paths if existing != path)]


def remove_exact(paths: Sequence[str], path: str) -> list[str]:
    return [existing for existing in paths if existing != path]


def set_search_list_argv(paths: Sequence[str]) -> list[str]:
    return [SECURITY, "list-keychains", "-d", "user", "-s", *paths]


def _run_security(args: Sequence[str], *, capture_stdout: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [SECURITY, *args],
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture_stdout else None,
    )


def read_search_list() -> list[str]:
    proc = _run_security(["list-keychains", "-d", "user"], capture_stdout=True)
    return parse_search_list(proc.stdout)


def write_search_list(paths: Sequence[str]) -> None:
    subprocess.run(set_search_list_argv(paths), check=True, text=True)


def read_default_keychain() -> str | None:
    proc = _run_security(["default-keychain", "-d", "user"], capture_stdout=True)
    return parse_default_keychain(proc.stdout)


def write_default_keychain(path: str) -> None:
    _run_security(["default-keychain", "-d", "user", "-s", path])


def cmd_prepend(path: str) -> int:
    current = read_search_list()
    updated = prepend_unique(current, path)
    if updated != current:
        write_search_list(updated)
    return 0


def cmd_remove(path: str) -> int:
    current = read_search_list()
    updated = remove_exact(current, path)
    if updated == current:
        return 0
    if not updated:
        print(
            "warn: skipping keychain search-list write after removing "
            f"{path}: security list-keychains -d user -s with zero paths is a no-op",
            file=sys.stderr,
        )
        return 0
    write_search_list(updated)
    return 0


def cmd_restore_default_if_current(owned_path: str, prior_path: str) -> int:
    current = read_default_keychain()
    if current == owned_path:
        write_default_keychain(prior_path)
        return 0

    current_label = current if current is not None else "(none)"
    print(
        "note: default keychain changed during ci; leaving it unchanged "
        f"({current_label})",
        file=sys.stderr,
    )
    return 0


def cmd_current_default() -> int:
    current = read_default_keychain()
    if current is None:
        print("error: default keychain is empty", file=sys.stderr)
        return 1
    print(current)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepend = subparsers.add_parser("prepend")
    prepend.add_argument("path")

    remove = subparsers.add_parser("remove")
    remove.add_argument("path")

    restore = subparsers.add_parser("restore-default-if-current")
    restore.add_argument("owned_path")
    restore.add_argument("prior_path")

    subparsers.add_parser("current-default")

    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "prepend":
            return cmd_prepend(args.path)
        if args.command == "remove":
            return cmd_remove(args.path)
        if args.command == "restore-default-if-current":
            return cmd_restore_default_if_current(args.owned_path, args.prior_path)
        if args.command == "current-default":
            return cmd_current_default()
    except (subprocess.CalledProcessError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    raise AssertionError(f"unhandled command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
