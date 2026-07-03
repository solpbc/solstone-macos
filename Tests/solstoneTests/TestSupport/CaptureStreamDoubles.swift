// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
@preconcurrency import ScreenCaptureKit
@testable import solstone

final class FakeCaptureStream: CaptureStreamControlling, @unchecked Sendable {
    let addStreamOutputCount = LockedCounter()
    let startCount = LockedCounter()
    let stopCount = LockedCounter()
    let updateCount = LockedCounter()

    private let lock = NSLock()
    private var startGates: [OneShotContinuationGate]
    private var stopGates: [OneShotContinuationGate]
    private var updateGates: [OneShotContinuationGate]

    init(
        startGates: [OneShotContinuationGate] = [],
        stopGates: [OneShotContinuationGate] = [],
        updateGates: [OneShotContinuationGate] = []
    ) {
        self.startGates = startGates
        self.stopGates = stopGates
        self.updateGates = updateGates
    }

    func addStreamOutput(
        _ output: any SCStreamOutput,
        type: SCStreamOutputType,
        sampleHandlerQueue: DispatchQueue?
    ) throws {
        addStreamOutputCount.increment()
    }

    func startCapture() async throws {
        startCount.increment()
        await popStartGate()?.wait()
    }

    func stopCapture() async throws {
        stopCount.increment()
        await popStopGate()?.wait()
    }

    func updateContentFilter(_ filter: SCContentFilter) async throws {
        updateCount.increment()
        await popUpdateGate()?.wait()
    }

    private func popStartGate() -> OneShotContinuationGate? {
        lock.withLock {
            guard !startGates.isEmpty else { return nil }
            return startGates.removeFirst()
        }
    }

    private func popStopGate() -> OneShotContinuationGate? {
        lock.withLock {
            guard !stopGates.isEmpty else { return nil }
            return stopGates.removeFirst()
        }
    }

    private func popUpdateGate() -> OneShotContinuationGate? {
        lock.withLock {
            guard !updateGates.isEmpty else { return nil }
            return updateGates.removeFirst()
        }
    }
}

@MainActor
final class FakeCaptureStreamFactory {
    private var queuedStreams: [FakeCaptureStream]
    private(set) var createdStreams: [FakeCaptureStream] = []
    private(set) var createdFilters: [SCContentFilter] = []

    init(_ streams: [FakeCaptureStream] = []) {
        self.queuedStreams = streams
    }

    func enqueue(_ stream: FakeCaptureStream) {
        queuedStreams.append(stream)
    }

    var factory: CaptureStreamFactory {
        { filter, _, _ in
            self.createdFilters.append(filter)
            let stream: FakeCaptureStream
            if self.queuedStreams.isEmpty {
                stream = FakeCaptureStream()
            } else {
                stream = self.queuedStreams.removeFirst()
            }
            self.createdStreams.append(stream)
            return stream
        }
    }
}
