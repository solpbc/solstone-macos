// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import CoreVideo
import Foundation
import Observation
@preconcurrency import ScreenCaptureKit
import Testing
@testable import solstone

@Suite("Screenshot preview")
@MainActor
struct ScreenshotPreviewTests {
    @Test func initiallyIneligiblePreviewObservesSourceCommitAndFirstFrame() throws {
        let dir = try makeTempDirectory("screenshot-preview-observation")
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState.forSnapshot(
            config: AppConfig(isScreenCaptureEnabled: true, isMicrophoneCaptureEnabled: false),
            permissionPollScheduler: PermissionPollTestScheduler().scheduler
        )
        defer { try? FileManager.default.removeItem(at: state.setupModel.continuationStore.directory) }
        state.capture.publishScreenRecordingPermission(.granted)
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let frame = try #require(context.makeImage())
        let initialInvalidations = LockedCounter()
        let initialFrame = withObservationTracking {
            state.latestFrame
        } onChange: {
            initialInvalidations.increment()
        }
        #expect(initialFrame == nil)
        #expect(!state.isLiveScreenPreviewEligible)

        state.captureManager.seedRecordingForTesting(
            currentSegment: FakeCaptureSegment(outputDirectory: dir), sources: .screen
        )
        // No image has changed yet: nil-to-nil invalidation need not notify. The
        // original subscription must still observe the first image after source commit.
        #expect(initialInvalidations.count == 0)
        state.captureManager.onLatestFrame?(frame, 1, state.previewEpoch)
        #expect(initialInvalidations.count == 1)
        #expect(state.latestFrame != nil)
    }

    @Test func idleFramesRecoverPreviewAfterStartupAndRespectPauseEpochs() async throws {
        let dir = try makeTempDirectory("screenshot-preview-idle")
        defer { try? FileManager.default.removeItem(at: dir) }
        let startGate = OneShotContinuationGate()
        defer { startGate.release() }
        let stream = FakeCaptureStream(startGates: [startGate])
        let factory = FakeCaptureStreamFactory([stream])
        let state = AppState.forSnapshot(
            config: AppConfig(isScreenCaptureEnabled: true, isMicrophoneCaptureEnabled: false),
            permissionPollScheduler: PermissionPollTestScheduler().scheduler
        )
        defer { try? FileManager.default.removeItem(at: state.setupModel.continuationStore.directory) }
        state.capture.publishScreenRecordingPermission(.granted)
        var screenshotCapturer: ScreenshotCapturer?
        let writer = SegmentWriter(
            outputDirectory: dir, timePrefix: "120000",
            screenshotCapturerFactory: { info, url, rate, duration, filter, verbose in
                let capturer = try ScreenshotCapturer(
                    displayID: info.displayID, videoURL: url, width: info.width, height: info.height,
                    frameRate: rate, duration: duration, contentFilter: try #require(filter),
                    verbose: verbose, streamFactory: factory.factory
                )
                screenshotCapturer = capturer
                return capturer
            },
            audioManagerFactory: { _, _, _, _ in FakeAudioManager() }
        )
        // Exercise the real protocol witnesses and SegmentWriter's capturer wiring.
        let segment: any CaptureSegmentWriting = writer
        segment.currentPreviewEpoch = state.captureManager.currentPreviewEpoch
        var delivered = 0
        segment.onLatestFrame = { [weak state] image, generation, epoch in
            delivered += 1
            state?.captureManager.onLatestFrame?(image, generation, epoch)
        }
        let display = DisplayInfo(displayID: 42, width: 1920, height: 1080,
                                  bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let starting = Task {
            try await segment.start(sources: .screen, displayInfos: [display],
                                    filters: [42: SCContentFilter()], audioFilter: nil,
                                    mics: [], micCaptureManager: nil, systemAudioCaptureManager: nil)
        }
        do {
            try await waitUntil { stream.startCount.count == 1 }
            let output = try #require(stream.outputs.first as? VideoStreamOutput)
            var rawBuffer: CVPixelBuffer?
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            try #require(CVPixelBufferCreate(kCFAllocatorDefault, 1920, 1080,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes, &rawBuffer) == kCVReturnSuccess)
            let buffer = try #require(rawBuffer)
            // Synthetic pixels only: initialize both planes before conversion/encoding.
            CVPixelBufferLockBaseAddress(buffer, [])
            for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
                if let address = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) {
                    memset(address, plane == 0 ? 96 : 128,
                           CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            output.onFrame(buffer, false)
            try await waitUntil { delivered == 1 }
            #expect(!state.isLiveScreenPreviewEligible)
            #expect(state.latestFrame == nil)
            let capturer = try #require(screenshotCapturer)
            #expect(capturer._submittedVideoFrameCountForTesting == 1)
            startGate.release()
            _ = try await starting.value
            state.captureManager.seedRecordingForTesting(currentSegment: segment, sources: .screen)
            #expect(state.isLiveScreenPreviewEligible)
            #expect(state.latestFrame == nil)

            // No more changed frames are necessary after the screen source becomes active.
            output.onFrame(buffer, true)
            try await waitUntil { delivered == 2 }
            let preview = try #require(state.latestFrame)
            #expect(preview.width == 640)
            #expect(preview.height == 360)

            // This queued frame belongs to the epoch before Pause and must be discarded.
            output.onFrame(buffer, true)
            state.pauseManager.pause(for: .indefinite)
            try await waitUntil { delivered == 3 }
            #expect(state.latestFrame == nil)
            // A buffer queued during Pause cannot reappear after Resume either.
            output.onFrame(buffer, true)
            state.pauseManager.resume()
            try await waitUntil { delivered == 4 }
            #expect(state.latestFrame == nil)
            output.onFrame(buffer, true)
            try await waitUntil { delivered == 5 }
            #expect(state.latestFrame != nil)

            state.captureManager.recordScreenFailure(.stopped)
            output.onFrame(buffer, true)
            try await waitUntil { delivered == 6 }
            #expect(state.latestFrame == nil)
            // Count submissions at the capture boundary, independently of encoded-container
            // sample representation: the five idle preview deliveries must add none.
            #expect(capturer._submittedVideoFrameCountForTesting == 1)
            _ = await segment.finishCapture()
        } catch {
            startGate.release()
            _ = try? await starting.value
            _ = await segment.finishCapture()
            throw error
        }
    }
}
