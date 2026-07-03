// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@MainActor
@Suite("CaptureCoordinator")
struct CaptureCoordinatorTests {
    @Test func stateChangeProjectsSynchronously() throws {
        let (coordinator, root) = try makeCoordinator()
        defer { try? FileManager.default.removeItem(at: root) }
        var bannerMessages: [String?] = []
        coordinator.handleCaptureStateChange(.recording)

        #expect(coordinator.isRecording)
        #expect(!coordinator.capturePaused)
        #expect(coordinator.captureError == nil)
        #expect(bannerMessages.isEmpty)

        let (sinkCoordinator, sinkRoot) = try makeCoordinator(bannerSink: { bannerMessages.append($0) })
        defer { try? FileManager.default.removeItem(at: sinkRoot) }

        sinkCoordinator.handleCaptureStateChange(.recording)

        #expect(sinkCoordinator.isRecording)
        #expect(bannerMessages == [nil])
    }

    @Test func concurrentStartsEnterStartOperationOnce() async throws {
        var callCount = 0
        var continuation: CheckedContinuation<Void, Never>?
        let (coordinator, root) = try makeCoordinator(startOperation: { _ in
            callCount += 1
            await withCheckedContinuation { pending in
                continuation = pending
            }
        })
        defer { try? FileManager.default.removeItem(at: root) }

        let first = Task { @MainActor in
            await coordinator.startRecording()
        }
        for _ in 0..<100 where callCount == 0 {
            await Task.yield()
        }
        #expect(callCount == 1)

        let second = Task { @MainActor in
            await coordinator.startRecording()
        }
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(callCount == 1)
        let pending = try #require(continuation)
        pending.resume()
        await first.value
        await second.value
    }

    @Test func startLatchReleasesAfterSuccessAndThrow() async throws {
        var successCount = 0
        let (successCoordinator, successRoot) = try makeCoordinator(startOperation: { _ in
            successCount += 1
        })
        defer { try? FileManager.default.removeItem(at: successRoot) }

        await successCoordinator.startRecording()
        await successCoordinator.startRecording()

        #expect(successCount == 2)

        enum StartFailure: Error {
            case failed
        }

        var throwCount = 0
        var bannerMessages: [String?] = []
        let (throwCoordinator, throwRoot) = try makeCoordinator(
            bannerSink: { bannerMessages.append($0) },
            startOperation: { _ in
                throwCount += 1
                if throwCount == 1 {
                    throw StartFailure.failed
                }
            }
        )
        defer { try? FileManager.default.removeItem(at: throwRoot) }

        await throwCoordinator.startRecording()
        await throwCoordinator.startRecording()

        #expect(throwCount == 2)
        #expect(throwCoordinator.captureError == UICopy.ERROR_START_OBSERVING)
        #expect(bannerMessages == [UICopy.ERROR_START_OBSERVING])
    }

    @Test func captureStateIngestionControlsPermissionPollingAndBanner() throws {
        var bannerMessages: [String?] = []
        let (coordinator, root) = try makeCoordinator(bannerSink: { bannerMessages.append($0) })
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(!coordinator.isPermissionPollingActiveForTesting)

        coordinator.handleCaptureStateChange(.idle)
        #expect(coordinator.isPermissionPollingActiveForTesting)
        #expect(bannerMessages.isEmpty)

        coordinator.handleCaptureStateChange(.recording)
        #expect(!coordinator.isPermissionPollingActiveForTesting)
        #expect(bannerMessages == [nil])

        coordinator.handleCaptureStateChange(.error("boom"))
        #expect(coordinator.isPermissionPollingActiveForTesting)
        #expect(bannerMessages == [nil, "boom"])
        #expect(coordinator.captureError == "boom")

        coordinator.handleCaptureStateChange(.recording)
        #expect(!coordinator.isPermissionPollingActiveForTesting)
    }

    private func makeCoordinator(
        isTerminating: @escaping CaptureCoordinator.IsTerminatingProvider = { false },
        configProvider: @escaping CaptureCoordinator.MicUIDConfigProvider = {
            (disabled: Set<String>(), enabled: Set<String>())
        },
        bannerSink: @escaping CaptureCoordinator.BannerSink = { _ in },
        startOperation: CaptureCoordinator.StartOperation? = nil
    ) throws -> (CaptureCoordinator, URL) {
        let root = try makeTempDirectory("capture-coordinator")
        let captureManager = CaptureManager(storageManager: StorageManager(baseDirectory: root))
        let coordinator = CaptureCoordinator(
            captureManager: captureManager,
            pauseManager: PauseManager(),
            audioDeviceMonitor: AudioDeviceMonitor(startListening: false),
            isTerminating: isTerminating,
            configProvider: configProvider,
            bannerSink: bannerSink,
            startOperation: startOperation
        )
        return (coordinator, root)
    }
}
