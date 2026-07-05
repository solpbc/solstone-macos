#!/usr/bin/env python3
"""Smoke-test journal.app's bundled runtime materialization without mutating it."""

from __future__ import annotations

import os
import pathlib
import subprocess
import sys
import tempfile


TIMEOUT_SECONDS = 180


def die(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def exactly_one_leaf_wheel(wheelhouse: pathlib.Path, pin: str) -> pathlib.Path:
    matches = sorted(wheelhouse.glob(f"solstone_journal-{pin}-*.whl"))
    if len(matches) != 1:
        die(f"error: expected exactly one solstone_journal-{pin}-*.whl in {wheelhouse}, found {len(matches)}")
    return matches[0]


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: journal_materialize_smoke.py <journal.app> <solstone-pin-version>", file=sys.stderr)
        return 2

    app = pathlib.Path(argv[0]).resolve()
    pin = argv[1]
    resources = app / "Contents" / "Resources"
    uv = resources / "uv"
    python = resources / "python" / "bin" / "python3.13"
    wheelhouse = resources / "wheelhouse"

    if not app.is_dir():
        die(f"error: {app} not found — run make bundle-dist-journal first")
    if not uv.is_file():
        die(f"error: bundled uv missing at {uv}")
    if not python.is_file():
        die(f"error: bundled python missing at {python}")
    if not wheelhouse.is_dir():
        die(f"error: bundled wheelhouse missing at {wheelhouse}")

    leaf = exactly_one_leaf_wheel(wheelhouse, pin)

    with tempfile.TemporaryDirectory(prefix="journal-materialize-smoke.") as temp:
        root = pathlib.Path(temp)
        env = os.environ.copy()
        env["UV_PYTHON_INSTALL_DIR"] = str(root / "python")
        env["UV_PYTHON_CACHE_DIR"] = str(root / "python")
        env["UV_CACHE_DIR"] = str(root / "cache")
        env["UV_TOOL_DIR"] = str(root / "tools")
        env["UV_TOOL_BIN_DIR"] = str(root / "bin")

        command = [
            str(uv),
            "tool",
            "install",
            str(leaf),
            "--with-executables-from",
            "solstone",
            "--find-links",
            str(wheelhouse),
            "--no-index",
            "--offline",
            "--python",
            str(python),
            "--no-python-downloads",
            "--force",
        ]
        try:
            subprocess.run(command, env=env, check=True, timeout=TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            die(f"error: journal runtime materialize smoke timed out after {TIMEOUT_SECONDS}s")
        except subprocess.CalledProcessError as error:
            return error.returncode

        for name in ("sol", "journal"):
            executable = root / "bin" / name
            if not os.access(executable, os.X_OK):
                die(f"error: expected executable missing after materialize smoke: {executable}")

    print("journal-materialize-smoke: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
