# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc

import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS AppKit run loop")
class AppKitTerminationTests(unittest.TestCase):
    def test_prepared_quit_allows_async_reply_and_exits(self):
        # Compile the production callout, not a copy. An in-process actor test
        # cannot expose AppKit's nested loop starving a main-queue callout.
        with tempfile.TemporaryDirectory(prefix="solstone-quit-test-") as scratch:
            scratch = pathlib.Path(scratch)
            source = scratch / "main.swift"
            source.write_text(r'''
import AppKit
import Foundation

func witness(_ value: String) {
    FileHandle.standardOutput.write(Data((value + "\n").utf8))
}
@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        witness("delegate.begin")
        Task { @MainActor in
            // The production diagnostic drain similarly suspends before reply.
            await Task.yield()
            witness("reply.true")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        witness("will.terminate")
    }
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.prohibited)
DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
    witness("WATCHDOG_TIMEOUT")
    _exit(42)
}
DispatchQueue.main.async {
    if CommandLine.arguments[1] == "task" {
        Task { @MainActor in terminateFromMainRunLoop() }
    } else {
        terminateFromMainRunLoop()
    }
}
app.run()
''')
            binary = scratch / "QuitProbe"
            compiled = subprocess.run(
                ["xcrun", "swiftc", "-swift-version", "6", str(source),
                 str(ROOT / "Sources/solstone/AppKitTerminationCallout.swift"),
                 "-o", str(binary)],
                capture_output=True, text=True, timeout=120,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            for entry in ("dispatch", "task"):
                with self.subTest(entry=entry):
                    result = subprocess.run(
                        [str(binary), entry], capture_output=True, text=True, timeout=20,
                    )
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(result.stdout.splitlines(),
                                     ["delegate.begin", "reply.true", "will.terminate"])
