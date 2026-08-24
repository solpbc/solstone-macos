// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@MainActor
final class DiagnosticEvidenceHarness {
    let clock: TestClock
    let bytes: InMemoryDiagnosticEvidenceBytesStore
    let store: DiagnosticEvidenceStore
    let recorder: DiagnosticEvidenceRecorder

    init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        let clock = TestClock(now)
        let bytes = InMemoryDiagnosticEvidenceBytesStore()
        self.clock = clock
        self.bytes = bytes
        self.store = DiagnosticEvidenceStore(bytesStore: bytes, now: { clock.now })
        self.recorder = DiagnosticEvidenceRecorder(store: store, now: { clock.now })
    }

    func entries() async -> [DiagnosticEvidenceEntry] {
        await recorder.drain()
        guard case .available(let envelope) = await store.read() else {
            return []
        }
        return envelope.entries
    }
}

@MainActor
final class EvidenceStartSpy {
    var count = 0
}

@MainActor
func makeScreenPermissionProvider(
    prompted: Bool = true,
    preflight: Bool = true,
    screenGranted: Bool = true,
    reset: @escaping @MainActor @Sendable () -> Void = {}
) -> ScreenRecordingPermissionProvider {
    ScreenRecordingPermissionProvider(
        hasPrompted: { prompted },
        preflight: { preflight },
        checkScreenRecording: { screenGranted },
        resetPromptedFlag: reset
    )
}

@MainActor
func makeEvidenceCoordinator(
    recorder: DiagnosticEvidenceRecorder,
    screenPermissionProvider: ScreenRecordingPermissionProvider,
    isTerminating: @escaping CaptureCoordinator.IsTerminatingProvider = { false },
    startOperation: CaptureCoordinator.StartOperation? = nil,
    logAdapter: DiagnosticEvidenceLoggingAdapter = DiagnosticEvidenceLoggingAdapter()
) throws -> (CaptureCoordinator, URL) {
    let root = URL(fileURLWithPath: "/var/tmp", isDirectory: true)
        .appendingPathComponent("solstone-evidence-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let coordinator = CaptureCoordinator(
        captureManager: CaptureManager(storageManager: StorageManager(baseDirectory: root)),
        pauseManager: PauseManager(),
        audioDeviceMonitor: AudioDeviceMonitor(startListening: false),
        isTerminating: isTerminating,
        configProvider: { (disabled: [], enabled: []) },
        bannerSink: { _ in },
        startOperation: startOperation,
        recorder: recorder,
        screenPermissionProvider: screenPermissionProvider,
        logAdapter: logAdapter
    )
    return (coordinator, root)
}

func evidenceCodes(_ entries: [DiagnosticEvidenceEntry]) -> [DiagnosticEvidenceCode] {
    entries.map(\.code)
}
