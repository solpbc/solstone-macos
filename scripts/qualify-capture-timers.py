#!/usr/bin/env python3
"""Explicit native tracking-mode gate; excluded from routine unit CI."""
import pathlib
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parent.parent
probes = {
    "capture-timers": ["Sources/solstone/CaptureTimer.swift", "scripts/probes/CaptureTimerTracking.swift"],
    "pause-countdown": ["Sources/solstone/PauseManager.swift", "scripts/probes/PauseCountdownTracking.swift"],
}
with tempfile.TemporaryDirectory(prefix="solstone-capture-timers-") as temporary:
    for name, sources in probes.items():
        binary = pathlib.Path(temporary) / name
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
            *(str(repo / source) for source in sources), "-o", str(binary),
        ], check=True, timeout=90)
        subprocess.run([str(binary)], check=True, timeout=15)
