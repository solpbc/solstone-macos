// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit
@testable import solstone

func makeTestPixelBuffer(width: Int = 16, height: Int = 16) -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        nil,
        &pixelBuffer
    )
    precondition(status == kCVReturnSuccess && pixelBuffer != nil)
    return pixelBuffer!
}

func makeTestSampleBuffer(
    pixelBuffer: CVPixelBuffer,
    status: SCFrameStatus = .complete,
    displayTime: UInt64? = nil
) -> CMSampleBuffer {
    var formatDesc: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDesc
    )
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 60),
        presentationTimeStamp: .zero,
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: formatDesc!,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
    )
    let buffer = sampleBuffer!
    let arr = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true)!
    let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
    CFDictionarySetValue(
        dict,
        Unmanaged.passUnretained(SCStreamFrameInfo.status.rawValue as NSString).toOpaque(),
        Unmanaged.passUnretained(NSNumber(value: status.rawValue)).toOpaque()
    )
    if let dt = displayTime {
        CFDictionarySetValue(
            dict,
            Unmanaged.passUnretained(SCStreamFrameInfo.displayTime.rawValue as NSString).toOpaque(),
            Unmanaged.passUnretained(NSNumber(value: dt)).toOpaque()
        )
    }
    return buffer
}

final class FakeCaptureStream: CaptureStreamControlling, @unchecked Sendable {
    let addStreamOutputCount = LockedCounter()
    let startCount = LockedCounter()
    let stopCount = LockedCounter()
    let updateCount = LockedCounter()

    private let lock = NSLock()
    private let startError: Error?
    private let addOutputError: Error?
    private var storedStopError: Error?
    private var storedUpdateError: Error?
    private var storedUpdatedFilters: [SCContentFilter] = []
    var stopError: Error? { get { lock.withLock { storedStopError } } set { lock.withLock { storedStopError = newValue } } }
    var updateError: Error? { get { lock.withLock { storedUpdateError } } set { lock.withLock { storedUpdateError = newValue } } }
    var updatedFilters: [SCContentFilter] { lock.withLock { storedUpdatedFilters } }
    private var startGates: [OneShotContinuationGate]
    private var stopGates: [OneShotContinuationGate]
    private var updateGates: [OneShotContinuationGate]

    private var storedOutputs: [any SCStreamOutput] = []
    var outputs: [any SCStreamOutput] { lock.withLock { storedOutputs } }

    init(
        startGates: [OneShotContinuationGate] = [],
        stopGates: [OneShotContinuationGate] = [],
        updateGates: [OneShotContinuationGate] = [],
        startError: Error? = nil,
        addOutputError: Error? = nil,
        stopError: Error? = nil,
        updateError: Error? = nil
    ) {
        self.startError = startError
        self.addOutputError = addOutputError
        self.storedStopError = stopError
        self.storedUpdateError = updateError
        self.startGates = startGates
        self.stopGates = stopGates
        self.updateGates = updateGates
    }

    func addStreamOutput(
        _ output: any SCStreamOutput,
        type: SCStreamOutputType,
        sampleHandlerQueue: DispatchQueue?
    ) throws {
        lock.withLock { storedOutputs.append(output) }
        addStreamOutputCount.increment()
        if let addOutputError {
            throw addOutputError
        }
    }

    func startCapture() async throws {
        startCount.increment()
        await popStartGate()?.wait()
        if let startError {
            throw startError
        }
    }

    func stopCapture() async throws {
        stopCount.increment()
        await popStopGate()?.wait()
        if let stopError { throw stopError }
    }

    func updateContentFilter(_ filter: SCContentFilter) async throws {
        updateCount.increment()
        lock.withLock { storedUpdatedFilters.append(filter) }
        await popUpdateGate()?.wait()
        if let updateError { throw updateError }
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
    private(set) var createdDelegates: [solstone.StreamDelegate] = []

    init(_ streams: [FakeCaptureStream] = []) {
        self.queuedStreams = streams
    }

    func enqueue(_ stream: FakeCaptureStream) {
        queuedStreams.append(stream)
    }

    var factory: CaptureStreamFactory {
        { filter, _, delegate in
            self.createdFilters.append(filter)
            self.createdDelegates.append(delegate)
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
