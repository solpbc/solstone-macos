#!/usr/bin/env python3
"""Fail-closed source binding and receipt for the native journal payload."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from datetime import datetime, timezone


SHA40_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def git(source_dir: pathlib.Path, *args: str) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(source_dir), *args],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        die(f"cannot inspect journal source {source_dir}: {exc}")
    return result.stdout.strip()


def verify_source(source_dir: pathlib.Path, expected_commit: str) -> str:
    if not SHA40_RE.fullmatch(expected_commit):
        die("JOURNAL_NATIVE_EXPECTED_COMMIT must be an exact 40-character lowercase commit")
    source_dir = source_dir.resolve()
    if git(source_dir, "rev-parse", "--is-inside-work-tree") != "true":
        die(f"journal source is not a git worktree: {source_dir}")
    actual_commit = git(source_dir, "rev-parse", "HEAD")
    if actual_commit != expected_commit:
        die(
            f"journal source HEAD is {actual_commit}, expected {expected_commit}; "
            "refusing to package a different revision"
        )
    dirty = git(source_dir, "status", "--porcelain=v1", "--untracked-files=all")
    if dirty:
        die(f"journal source is dirty at {source_dir}; refusing to package\n{dirty}")
    return actual_commit


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def runtime_entries(runtime_dir: pathlib.Path) -> dict[str, dict[str, str]]:
    entries = {}
    for name in ("journal", "solstone"):
        entry = runtime_dir / "bin" / name
        if not entry.is_file() or not os.access(entry, os.X_OK):
            die(f"native journal runtime is missing executable bin/{name}")
        entries[name] = {"path": f"bin/{name}", "sha256": sha256(entry)}
    return entries


def store_receipt(receipt: dict, receipt_path: pathlib.Path) -> None:
    receipt_path = receipt_path.resolve()
    receipt_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=receipt_path.parent,
        prefix=f".{receipt_path.name}.",
        delete=False,
    ) as handle:
        json.dump(receipt, handle, indent=2, sort_keys=True)
        handle.write("\n")
        temporary_path = pathlib.Path(handle.name)
    temporary_path.replace(receipt_path)


def extract_regular_tree(bundle: tarfile.TarFile, destination: pathlib.Path) -> None:
    """Extract a link-free archive without relying on Python 3.12 filters."""
    seen: set[str] = set()
    for member in bundle.getmembers():
        name = member.name.rstrip("/")
        parts = name.split("/")
        if (
            not name
            or member.name.startswith("/")
            or any(part in ("", ".", "..") for part in parts)
        ):
            die(f"accepted journal archive has an unsafe member path: {member.name}")
        if name in seen:
            die(f"accepted journal archive has a duplicate member path: {name}")
        seen.add(name)

        target = destination.joinpath(*parts)
        if member.isdir():
            target.mkdir(parents=True, exist_ok=True)
            # Keep staging traversable even when the archive declares a
            # restrictive directory; no archive mode may block later members.
            target.chmod(0o755)
            continue
        if not member.isfile():
            die(
                "accepted journal archive member is not a regular file or directory: "
                f"{member.name}"
            )

        target.parent.mkdir(parents=True, exist_ok=True)
        source = bundle.extractfile(member)
        if source is None:
            die(f"accepted journal archive member cannot be read: {member.name}")
        with source, target.open("xb") as output:
            shutil.copyfileobj(source, output)
        mode = member.mode & 0o755
        if not mode & 0o100:
            mode &= ~0o111
        target.chmod(mode | 0o600)


def write_receipt(args: argparse.Namespace) -> None:
    source_dir = pathlib.Path(args.source_dir).resolve()
    actual_commit = verify_source(source_dir, args.expected_commit)
    output_dir = pathlib.Path(args.output_dir).resolve()
    archives = sorted(output_dir.glob("*.tar.gz"))
    if len(archives) != 1 or not archives[0].is_file():
        die(f"expected exactly one native journal archive in {output_dir}")

    runtime_dir = pathlib.Path(args.runtime_dir).resolve()
    entries = runtime_entries(runtime_dir)

    receipt = {
        "schema": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "source": {
            "checkout_path": str(source_dir),
            "commit": actual_commit,
            "clean": True,
        },
        "target": args.target,
        "archive": {
            "name": archives[0].name,
            "sha256": sha256(archives[0]),
            "length": archives[0].stat().st_size,
        },
        "entries": entries,
    }

    receipt_path = pathlib.Path(args.receipt).resolve()
    store_receipt(receipt, receipt_path)
    print(
        f"journal native provenance: {actual_commit} -> "
        f"{archives[0].name} ({receipt_path})"
    )


def stage_accepted(args: argparse.Namespace) -> None:
    if not SHA40_RE.fullmatch(args.expected_commit):
        die("JOURNAL_NATIVE_EXPECTED_COMMIT must be an exact 40-character lowercase commit")
    if not SHA256_RE.fullmatch(args.expected_sha256):
        die("JOURNAL_NATIVE_ACCEPTED_SHA256 must be an exact lowercase SHA-256")
    if not args.acceptance_evidence.strip():
        die("JOURNAL_NATIVE_ACCEPTANCE_EVIDENCE must name the journal lane's evidence")

    archive_input = pathlib.Path(args.archive)
    if archive_input.is_symlink():
        die(f"accepted journal archive must not be a symlink: {archive_input}")
    try:
        archive = archive_input.resolve(strict=True)
    except OSError as exc:
        die(f"accepted journal archive cannot be resolved: {archive_input}: {exc}")
    if not archive.is_file():
        die(f"accepted journal archive is not a regular file: {archive}")
    actual_sha256 = sha256(archive)
    if actual_sha256 != args.expected_sha256:
        die(
            f"accepted journal archive SHA-256 is {actual_sha256}, expected "
            f"{args.expected_sha256}"
        )

    runtime_input = pathlib.Path(args.runtime_dir)
    if runtime_input.is_symlink():
        die(f"native journal runtime destination must not be a symlink: {runtime_input}")
    runtime_dir = runtime_input.resolve()
    workspace_root = pathlib.Path(args.workspace_root).resolve(strict=True)
    if runtime_dir == workspace_root or not runtime_dir.is_relative_to(workspace_root):
        die(
            f"native journal runtime destination must be inside the workspace: {runtime_dir}"
        )
    if runtime_dir.exists() and not runtime_dir.is_dir():
        die(f"native journal runtime destination is not a directory: {runtime_dir}")

    receipt_path = pathlib.Path(args.receipt).resolve()
    if receipt_path == runtime_dir or not receipt_path.is_relative_to(runtime_dir):
        die(f"accepted journal receipt must be inside the runtime directory: {receipt_path}")
    receipt_relative = receipt_path.relative_to(runtime_dir)

    runtime_dir.parent.mkdir(parents=True, exist_ok=True)
    staged_dir = pathlib.Path(
        tempfile.mkdtemp(prefix=f".{runtime_dir.name}.", dir=runtime_dir.parent)
    )
    try:
        with tarfile.open(archive, mode="r:gz") as bundle:
            extract_regular_tree(bundle, staged_dir)
        entries = runtime_entries(staged_dir)

        receipt = {
            "schema": 1,
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "mode": "accepted-archive",
            "source": {
                "commit": args.expected_commit,
                "acceptance_evidence": args.acceptance_evidence,
            },
            "target": args.target,
            "archive": {
                "name": archive.name,
                "sha256": actual_sha256,
                "length": archive.stat().st_size,
            },
            "entries": entries,
        }
        store_receipt(receipt, staged_dir / receipt_relative)

        if runtime_dir.exists():
            shutil.rmtree(runtime_dir)
        os.replace(staged_dir, runtime_dir)
    except (OSError, tarfile.TarError) as exc:
        die(f"cannot extract accepted journal archive {archive}: {exc}")
    finally:
        if staged_dir.exists():
            shutil.rmtree(staged_dir)
    print(
        f"accepted journal archive verified: {args.expected_commit} "
        f"{actual_sha256} receipt={receipt_path}"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    check = subparsers.add_parser("check-source")
    check.add_argument("--source-dir", required=True)
    check.add_argument("--expected-commit", required=True)

    write = subparsers.add_parser("write-receipt")
    write.add_argument("--source-dir", required=True)
    write.add_argument("--expected-commit", required=True)
    write.add_argument("--target", required=True)
    write.add_argument("--output-dir", required=True)
    write.add_argument("--runtime-dir", required=True)
    write.add_argument("--receipt", required=True)

    accepted = subparsers.add_parser("stage-accepted")
    accepted.add_argument("--archive", required=True)
    accepted.add_argument("--expected-sha256", required=True)
    accepted.add_argument("--expected-commit", required=True)
    accepted.add_argument("--acceptance-evidence", required=True)
    accepted.add_argument("--target", required=True)
    accepted.add_argument("--workspace-root", required=True)
    accepted.add_argument("--runtime-dir", required=True)
    accepted.add_argument("--receipt", required=True)

    args = parser.parse_args()
    if args.command == "check-source":
        commit = verify_source(pathlib.Path(args.source_dir), args.expected_commit)
        print(f"journal native source verified: {commit}")
    elif args.command == "write-receipt":
        write_receipt(args)
    else:
        stage_accepted(args)


if __name__ == "__main__":
    main()
