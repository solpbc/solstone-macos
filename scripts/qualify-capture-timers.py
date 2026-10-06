#!/usr/bin/env python3
"""Explicit native tracking-mode gate; excluded from routine unit CI."""
import pathlib
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="solstone-capture-timers-") as temporary:
    binary = pathlib.Path(temporary) / "capture-timers"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
        str(repo / "Sources/solstone/CaptureTimer.swift"),
        str(repo / "scripts/probes/CaptureTimerTracking.swift"), "-o", str(binary),
    ], check=True, timeout=45)
    subprocess.run([str(binary)], check=True, timeout=10)
