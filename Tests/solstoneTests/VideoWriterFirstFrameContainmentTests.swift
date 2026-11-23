// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import solstone

struct VideoWriterFirstFrameContainmentTests {
    @Test func firstFrameStartSessionExceptionIsContainedAndFinishFails() async throws {
        let root = try makeTempDirectory("video-first-frame-containment")
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = try VideoWriter.create(
            url: root.appendingPathComponent("screen.mp4"),
            width: 16,
            height: 16,
            frameRate: 1,
            duration: nil
        )
        let pixelBuffer = try makeNV12PixelBuffer(width: 16, height: 16)

        // Manual sanity check: removing the ObjCExceptionCatcher barrier around
        // startSession(atSourceTime:) should turn this path into a SIGABRT.
        writer.appendFrame(pixelBuffer, presentationTime: .invalid)

        let result: Result<(URL, Int), Error> = await withCheckedContinuation { continuation in
            writer.finish { result in
                continuation.resume(returning: result)
            }
        }

        switch result {
        case .success:
            Issue.record("expected first-frame start failure")
        case .failure(let error):
            let nsError = error as NSError
            #expect(nsError.domain == "VideoWriter")
            #expect(nsError.code == -5)
            #expect(nsError.localizedDescription == "Video writer failed to start (first-frame session start failed)")
        }
    }

    @Test func startedWriterWithZeroAppendedFramesFailsAndRemovesOutput() async throws {
        let root = try makeTempDirectory("video-zero-appended-frames")
        defer { try? FileManager.default.removeItem(at: root) }

        let outputURL = root.appendingPathComponent("screen.mp4")
        let writer = try VideoWriter.create(
            url: outputURL,
            width: 16,
            height: 16,
            frameRate: 1,
            duration: 0
        )
        let pixelBuffer = try makeNV12PixelBuffer(width: 16, height: 16)
        // duration: 0 starts the writer and session on the first frame, then returns
        // before appending because elapsed (0) >= duration (0), leaving frameCount == 0.
        writer.appendFrame(pixelBuffer, presentationTime: .zero)

        let result: Result<(URL, Int), Error> = await withCheckedContinuation { continuation in
            writer.finish { result in
                continuation.resume(returning: result)
            }
        }

        switch result {
        case .success:
            Issue.record("expected failure when no frames were appended")
        case .failure(let error):
            let nsError = error as NSError
            #expect(nsError.domain == "VideoWriter")
            #expect(nsError.code == -2)
            #expect(!FileManager.default.fileExists(atPath: outputURL.path))
        }
    }

    private func makeNV12PixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            nil,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw VideoWriterFirstFrameTestError.pixelBufferFailed(status)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
            guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else { continue }
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            let planeHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            memset(baseAddress, plane == 0 ? 0 : 128, bytesPerRow * planeHeight)
        }

        return pixelBuffer
    }
}

private enum VideoWriterFirstFrameTestError: Error {
    case pixelBufferFailed(CVReturn)
}
