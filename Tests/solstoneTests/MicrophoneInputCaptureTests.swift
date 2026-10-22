// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@preconcurrency import AVFAudio
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import SolstoneCore
import Testing
@testable import solstone

final class FakeMicrophoneInputUnit: MicrophoneInputUnit, @unchecked Sendable {
    private let lock = NSLock()
    var openStatus: OSStatus = noErr
    var inputEnabledStatus: OSStatus = noErr
    var outputEnabledStatus: OSStatus = noErr
    var setDeviceStatus: OSStatus = noErr
    var getDeviceStatus: OSStatus = noErr
    var boundDeviceID: AudioDeviceID = 0
    var getStreamFormatStatus: OSStatus = noErr
    var setStreamFormatStatus: OSStatus = noErr
    var streamFormat: AudioStreamBasicDescription
    var callbackStatus: OSStatus = noErr
    var initStatus: OSStatus = noErr
    var startStatus: OSStatus = noErr
    var stopStatus: OSStatus = noErr
    var uninitializeStatus: OSStatus = noErr
    var disposeStatus: OSStatus = noErr
    var renderStatus: OSStatus = noErr
    var clientFormatOverride: AudioStreamBasicDescription?
    var clientFormatByteSize: UInt32?
    var clientFormatStatus: OSStatus = noErr
    var boundDeviceByteSize: UInt32?
    var maximumFrames: UInt32 = 4096
    var maximumFramesByteSize: UInt32?
    var maximumFramesStatus: OSStatus = noErr
    var invokeCallbackOnStart = false
    var invokeCallbackOnStop = false
    var reenterOnRender = false
    var nestedStatus: OSStatus = noErr
    var nestedFrameCount: UInt32 = 64
    var boundDeviceReadback: AudioDeviceID?

    var renderCallback: AURenderCallback?
    var renderRefCon: UnsafeMutableRawPointer?
    var disposeCallCount: Int = 0
    var renderCallCount: Int = 0
    var onRender: (@Sendable () -> Void)?
    var onStop: (@Sendable () -> Void)?

    init(sampleRate: Float64 = 48000, channelCount: UInt32 = 1) {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = sampleRate
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved
        asbd.mBytesPerPacket = 4
        asbd.mFramesPerPacket = 1
        asbd.mBytesPerFrame = 4
        asbd.mChannelsPerFrame = channelCount
        asbd.mBitsPerChannel = 32
        self.streamFormat = asbd
    }

    func open() -> OSStatus { openStatus }
    func setInputEnabled(_ enabled: Bool) -> OSStatus { inputEnabledStatus }
    func setOutputEnabled(_ enabled: Bool) -> OSStatus { outputEnabledStatus }
    func setDeviceID(_ id: AudioDeviceID) -> OSStatus {
        boundDeviceID = id
        return setDeviceStatus
    }
    func getDeviceID() -> (status: OSStatus, deviceID: AudioDeviceID) {
        (getDeviceStatus, boundDeviceID)
    }
    func getStreamFormat() -> (status: OSStatus, format: AudioStreamBasicDescription) {
        (getStreamFormatStatus, streamFormat)
    }
    func setStreamFormat(_ asbd: AudioStreamBasicDescription) -> OSStatus {
        streamFormat = asbd
        return setStreamFormatStatus
    }
    func setRenderCallback(_ callback: @escaping AURenderCallback, refCon: UnsafeMutableRawPointer?) -> OSStatus {
        renderCallback = callback
        renderRefCon = refCon
        return callbackStatus
    }
    func initialize() -> OSStatus { initStatus }
    func uninitialize() -> OSStatus { uninitializeStatus }
    func start() -> OSStatus {
        if invokeCallbackOnStart, let renderCallback, let renderRefCon {
            var flags: AudioUnitRenderActionFlags = []
            var time = AudioTimeStamp()
            time.mHostTime = mach_absolute_time()
            var list = AudioBufferList()
            _ = renderCallback(renderRefCon, &flags, &time, 1, 512, &list)
        }
        return startStatus
    }
    func stop() -> OSStatus {
        if invokeCallbackOnStop, let renderCallback, let renderRefCon {
            var flags: AudioUnitRenderActionFlags = []
            var time = AudioTimeStamp()
            time.mHostTime = mach_absolute_time()
            var list = AudioBufferList()
            _ = renderCallback(renderRefCon, &flags, &time, 1, 512, &list)
        }
        onStop?()
        return stopStatus
    }
    func dispose() -> OSStatus {
        lock.withLock { disposeCallCount += 1 }
        return disposeStatus
    }
    func getClientStreamFormat() -> (status: OSStatus, format: AudioStreamBasicDescription, byteSize: UInt32) {
        let format = clientFormatOverride ?? streamFormat
        let size = clientFormatByteSize ?? UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return (clientFormatStatus, format, size)
    }
    func getBoundDevice() -> (status: OSStatus, deviceID: AudioDeviceID, byteSize: UInt32) {
        let size = boundDeviceByteSize ?? UInt32(MemoryLayout<AudioDeviceID>.size)
        return (getDeviceStatus, boundDeviceReadback ?? boundDeviceID, size)
    }
    func maximumFramesPerSlice() -> (status: OSStatus, frames: UInt32, byteSize: UInt32) {
        let size = maximumFramesByteSize ?? UInt32(MemoryLayout<UInt32>.size)
        return (maximumFramesStatus, maximumFrames, size)
    }
    func render(actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                timeStamp: UnsafePointer<AudioTimeStamp>,
                busNumber: UInt32,
                frameCount: UInt32,
                data: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        lock.withLock { renderCallCount += 1 }
        if reenterOnRender, let renderCallback, let renderRefCon {
            reenterOnRender = false
            var flags: AudioUnitRenderActionFlags = []
            var time = AudioTimeStamp()
            time.mHostTime = mach_absolute_time()
            var list = AudioBufferList()
            nestedStatus = renderCallback(renderRefCon, &flags, &time, 1, nestedFrameCount, &list)
        }
        onRender?()
        return renderStatus
    }
}

@Suite("MicrophoneInputCaptureTests", .serialized)
struct MicrophoneInputCaptureTests {

    // 1. Each ordinal against impulses on the other channels, including 10 channels
    @Test func eachOrdinalAgainstImpulsesOnOtherChannels10Channels() throws {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 10))
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: false,
            channelLayout: layout
        ))
        let frames: AVAudioFrameCount = 8
        let testOrdinals = [0, 2, 5, 9]

        for targetOrdinal in testOrdinals {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            let channels = try #require(buffer.floatChannelData)

            // Fill all channels with impulses, except targetOrdinal gets 0.42
            for ch in 0..<10 {
                for f in 0..<Int(frames) {
                    channels[ch][f] = (ch == targetOrdinal) ? 0.42 : 1.0
                }
            }

            let mono = try #require(ExternalMicCapture.extractChosenChannel(buffer, ordinal: targetOrdinal))
            #expect(mono.format.channelCount == 1)
            #expect(mono.format.sampleRate == 48_000)
            #expect(mono.frameLength == frames)

            let extracted = try #require(mono.floatChannelData)
            for f in 0..<Int(frames) {
                #expect(extracted[0][f] == 0.42)
            }
        }
    }

    // 2. Quiet chosen-channel amplitude beside a loud neighbor
    @Test func quietChosenChannelAmplitudeBesideLoudNeighbor() throws {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4))
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: false,
            channelLayout: layout
        ))
        let frames: AVAudioFrameCount = 4
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try #require(buffer.floatChannelData)

        for f in 0..<Int(frames) {
            channels[0][f] = 0.001 // Quiet chosen channel
            channels[1][f] = 0.99  // Loud neighbor
            channels[2][f] = 0.5
            channels[3][f] = 0.5
        }

        let quietMono = try #require(ExternalMicCapture.extractChosenChannel(buffer, ordinal: 0))
        let quietSamples = try #require(quietMono.floatChannelData)
        for f in 0..<Int(frames) {
            #expect(quietSamples[0][f] == 0.001)
        }

        let loudMono = try #require(ExternalMicCapture.extractChosenChannel(buffer, ordinal: 1))
        let loudSamples = try #require(loudMono.floatChannelData)
        for f in 0..<Int(frames) {
            #expect(loudSamples[0][f] == 0.99)
        }
    }

    // 3. Planar and interleaved Float32, and invalid ordinals rejected
    @Test func planarAndInterleavedFloat32AndMismatchRejected() throws {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3))

        // Planar (non-interleaved) Float32
        let planarFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: layout))
        let planarBuffer = try #require(AVAudioPCMBuffer(pcmFormat: planarFormat, frameCapacity: 4))
        planarBuffer.frameLength = 4
        let planarCh = try #require(planarBuffer.floatChannelData)
        for ch in 0..<3 {
            for f in 0..<4 { planarCh[ch][f] = Float(ch * 10 + f) }
        }
        let planarExtracted = try #require(ExternalMicCapture.extractChosenChannel(planarBuffer, ordinal: 1))
        let planarVals = try #require(planarExtracted.floatChannelData)[0]
        for f in 0..<4 { #expect(planarVals[f] == Float(10 + f)) }

        // Interleaved Float32
        let interleavedFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: true, channelLayout: layout))
        let interleavedBuffer = try #require(AVAudioPCMBuffer(pcmFormat: interleavedFormat, frameCapacity: 4))
        interleavedBuffer.frameLength = 4
        let interleavedCh = try #require(interleavedBuffer.floatChannelData)
        for ch in 0..<3 {
            for f in 0..<4 { interleavedCh[ch][f * interleavedBuffer.stride] = Float(ch * 10 + f) }
        }
        let interleavedExtracted = try #require(ExternalMicCapture.extractChosenChannel(interleavedBuffer, ordinal: 2))
        let interleavedVals = try #require(interleavedExtracted.floatChannelData)[0]
        for f in 0..<4 { #expect(interleavedVals[f] == Float(20 + f)) }

        // Out-of-range ordinal (negative or >= channelCount)
        #expect(ExternalMicCapture.extractChosenChannel(planarBuffer, ordinal: -1) == nil)
        #expect(ExternalMicCapture.extractChosenChannel(planarBuffer, ordinal: 3) == nil)
        #expect(ExternalMicCapture.extractChosenChannel(planarBuffer, ordinal: 99) == nil)

        // Non-Float32 PCM rejected
        let intFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, interleaved: false, channelLayout: layout))
        let intBuffer = try #require(AVAudioPCMBuffer(pcmFormat: intFormat, frameCapacity: 4))
        intBuffer.frameLength = 4
        #expect(ExternalMicCapture.extractChosenChannel(intBuffer, ordinal: 0) == nil)
    }

    // 4. Chosen-channel 44.1 kHz to 48 kHz through uneven production chunks.
    // A later choice must not keep the previous converter's samples.
    @Test func selectedInputConversion441To48UsesUnevenChunksAndDropsOldHistory() async throws {
        defer { microphoneNativeResetOwnersForTesting() }
        let uid = "rate-\(UUID().uuidString)"
        let device = AudioInputDevice(id: 1, name: "rate", uid: uid, manufacturer: nil, sampleRate: 44_100, transportType: .usb)
        let ten = micLayout(channels: 10)
        guard case .available(let layout) = ten else { Issue.record("layout"); return }
        let capture = ExternalMicCapture(
            device: device, gain: 1,
            engineFactory: { NativeMicrophoneCaptureEngine(unitFactory: { FakeMicrophoneInputUnit() }) },
            resolveDeviceID: { _ in 1 },
            layoutReader: { _ in ten }
        )
        defer { capture.stop() }
        #expect(capture.authorizeChoice(MicrophoneChoice(ordinal: 2, fingerprint: layout.fingerprint)))
        let samples = SampleBox()
        capture.setCallbacks(audio: { buffer, _ in samples.append(buffer) }, error: { _ in })
        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        for count: AVAudioFrameCount in [100, 250, 17] {
            let buffer = try markedBuffer(channels: 10, frames: count, rate: 44_100) { channel, _ in
                channel == 2 ? 0.5 : 0.95
            }
            capture._enqueueForTesting(buffer, targetFormat: target)
        }
        try await withTimeout(seconds: 5) { await capture.drain() }
        #expect(samples.values.count > 300)
        let mean = samples.values.reduce(Float(0), +) / Float(samples.values.count)
        #expect(abs(mean - 0.5) < 0.08)

        let before = samples.values.count
        #expect(capture.authorizeChoice(MicrophoneChoice(ordinal: 0, fingerprint: layout.fingerprint)))
        let silent = try markedBuffer(channels: 10, frames: 256, rate: 44_100) { channel, _ in
            channel == 0 ? 0 : 0.95
        }
        capture._enqueueForTesting(silent, targetFormat: target)
        try await withTimeout(seconds: 5) { await capture.drain() }
        let tail = samples.values.dropFirst(before)
        #expect(!tail.isEmpty)
        #expect(tail.allSatisfy { abs($0) < 0.05 })
    }

    // 5. Malformed choice decodes as nil and other rows load; invalid layout does not admit
    @Test func malformedChoiceDecodesAsNilAndPriorityRowsStillLoadAndInvalidLayoutDoesNotAdmit() throws {
        let json = """
        [
            {
                "uid": "mic-valid",
                "name": "Valid Mic",
                "isDisabled": false,
                "choice": {
                    "ordinal": 2,
                    "fingerprint": {
                        "streams": [{"startingChannel": 1, "channelCount": 4}]
                    }
                }
            },
            {
                "uid": "mic-malformed",
                "name": "Malformed Choice Mic",
                "isDisabled": false,
                "choice": {
                    "ordinal": -99,
                    "fingerprint": "corrupted"
                }
            },
            {
                "uid": "mic-plain",
                "name": "Plain Mic",
                "isDisabled": false
            }
        ]
        """.data(using: .utf8)!

        let entries = try JSONDecoder().decode([MicrophoneEntry].self, from: json)
        #expect(entries.count == 3)
        #expect(entries[0].uid == "mic-valid")
        #expect(entries[0].choice?.ordinal == 2)
        #expect(entries[1].uid == "mic-malformed")
        #expect(entries[1].choice == nil) // Caught non-throwing decode fallback
        #expect(entries[2].uid == "mic-plain")
        #expect(entries[2].choice == nil)

        // Invalid layout: stream spans with gap (starts at 1 count 2, next starts at 4 count 2)
        let invalidLayoutResult = MicrophoneMonitor.readLayout(
            deviceID: 1,
            queryStreams: { _ in [10, 20] },
            queryStreamSpan: { streamID in
                if streamID == 10 { return (startingChannel: 1, channelCount: 2) }
                if streamID == 20 { return (startingChannel: 4, channelCount: 2) } // Gap: channel 3 missing
                return nil
            },
            queryStreamConfigChannels: { _ in 4 }
        )
        #expect(invalidLayoutResult == .unavailable)

        let dev = AudioInputDevice(id: 1, name: "dev", uid: "dev", manufacturer: nil, sampleRate: 48_000, transportType: .usb)
        let classification = classifyMicrophone(device: dev, choice: nil, layoutResult: invalidLayoutResult)
        #expect(classification == .layoutUnavailable)
    }

    // 6. Device-ID churn with same layout keeps choice; aggregate member reorder does not
    @Test func deviceIDChurnKeepsChoiceAndAggregateMemberReorderClears() throws {
        let memberSpans = [
            MicrophoneLayoutFingerprint.AggregateMemberSpan(uid: "sub-1", inputChannelCount: 2),
            MicrophoneLayoutFingerprint.AggregateMemberSpan(uid: "sub-2", inputChannelCount: 2)
        ]
        let fingerprint = MicrophoneLayoutFingerprint(
            streams: [MicrophoneLayoutFingerprint.StreamSpan(startingChannel: 1, channelCount: 4)],
            aggregateMembers: memberSpans
        )
        let choice = MicrophoneChoice(ordinal: 1, fingerprint: fingerprint)

        let layout = MicrophoneMonitor.MicrophoneLayout(
            fingerprint: fingerprint,
            channelCount: 4,
            labels: [nil, nil, nil, nil]
        )

        // Device ID churn: device id 10 vs 20 with identical layout
        let dev10 = AudioInputDevice(id: 10, name: "agg", uid: "agg-uid", manufacturer: nil, sampleRate: 48_000, transportType: .aggregate)
        let dev20 = AudioInputDevice(id: 20, name: "agg", uid: "agg-uid", manufacturer: nil, sampleRate: 48_000, transportType: .aggregate)

        #expect(classifyMicrophone(device: dev10, choice: choice, layoutResult: .available(layout)) == .admitted)
        #expect(classifyMicrophone(device: dev20, choice: choice, layoutResult: .available(layout)) == .admitted)

        // Aggregate member reorder
        let reorderedMembers = [
            MicrophoneLayoutFingerprint.AggregateMemberSpan(uid: "sub-2", inputChannelCount: 2),
            MicrophoneLayoutFingerprint.AggregateMemberSpan(uid: "sub-1", inputChannelCount: 2)
        ]
        let reorderedFingerprint = MicrophoneLayoutFingerprint(
            streams: [MicrophoneLayoutFingerprint.StreamSpan(startingChannel: 1, channelCount: 4)],
            aggregateMembers: reorderedMembers
        )
        let reorderedLayout = MicrophoneMonitor.MicrophoneLayout(
            fingerprint: reorderedFingerprint,
            channelCount: 4,
            labels: [nil, nil, nil, nil]
        )

        let reorderedClass = classifyMicrophone(device: dev20, choice: choice, layoutResult: .available(reorderedLayout))
        #expect(reorderedClass != .admitted)
        if case .needsChoice = reorderedClass {
            #expect(true)
        } else {
            Issue.record("Expected .needsChoice on aggregate member reorder")
        }
    }

    // 7. Same-UID revocation drops queued audio. A normal rotation keeps the original writer, including the converter tail.
    @Test func sameUIDRevocationDropsQueuedAudioAndRotationKeepsOriginalWriterMedia() async throws {
        let root = try makeTempDirectory("mic-revocation")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { microphoneNativeResetOwnersForTesting() }
        let host = mach_absolute_time()
        let uid = "revoke-\(UUID().uuidString)"
        let device = AudioInputDevice(id: 1, name: "test-mic", uid: uid, manufacturer: nil, sampleRate: 48_000, transportType: .usb)
        let capture = ExternalMicCapture(
            device: device, gain: 1,
            engineFactory: { NativeMicrophoneCaptureEngine(unitFactory: { FakeMicrophoneInputUnit() }) },
            resolveDeviceID: { _ in 1 },
            layoutReader: { _ in testOneChannelLayout }
        )
        defer { capture.stop() }
        let writer = try SingleTrackAudioWriter(
            url: root.appendingPathComponent("source.m4a"),
            trackType: .microphone(name: device.name, deviceUID: device.uid),
            segmentStartTime: CMClockMakeHostTimeFromSystemUnits(host)
        )
        let delivered = CountBox()
        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        capture.setQueuedCallbacks(
            audio: { buffer, time in
                delivered.originalFrames += Int(buffer.frameLength)
                delivered.originalCalls += 1
                return capture.performIfPolicyCurrent { writer.enqueuePCMBuffer(buffer, presentationTime: time) }
            },
            error: { _ in },
            rawError: nil,
            admissionGate: nil
        )
        let first = try markedBuffer(channels: 1, frames: 256, rate: 48_000) { _, _ in 0.2 }
        capture._enqueueForTesting(first, targetFormat: target, when: hostAudioTime(host, frame: 0, rate: 48_000))
        try await withTimeout(seconds: 5) { await capture.drain() }
        #expect(delivered.originalCalls == 1)
        let accepted = writer.statisticsSnapshot.acceptedFrames
        #expect(accepted > 0)

        let buf44 = try markedBuffer(channels: 1, frames: 128, rate: 44_100) { _, _ in 0.2 }
        _ = capture._convertForTesting(buf44, targetFormat: target)
        #expect(capture._converterForTesting != nil)

        capture._suspendProcessingForTesting()
        let queued = try markedBuffer(channels: 1, frames: 128, rate: 48_000) { _, _ in 0.4 }
        capture._enqueueForTesting(queued, targetFormat: target, when: hostAudioTime(host, frame: 4_096, rate: 48_000))
        capture.revokeUnacceptedAudio()
        capture._resumeProcessingForTesting()
        try await withTimeout(seconds: 5) { await capture.drain() }
        capture._onWriterQueueForTesting {}
        #expect(delivered.originalCalls == 1)
        #expect(writer.statisticsSnapshot.acceptedFrames == accepted)
        #expect(capture._converterForTesting == nil)

        // Revocation disabled recording. A mono clear admits again, then rotation keeps already queued media on the old writer.
        #expect(capture.authorizeChoice(nil))
        let successor = try SingleTrackAudioWriter(
            url: root.appendingPathComponent("next.m4a"),
            trackType: .microphone(name: device.name, deviceUID: device.uid),
            segmentStartTime: CMClockMakeHostTimeFromSystemUnits(host)
        )
        capture._suspendProcessingForTesting()
        let rotating = try markedBuffer(channels: 1, frames: 180, rate: 44_100) { _, _ in 0.45 }
        capture._enqueueForTesting(rotating, targetFormat: target, when: hostAudioTime(host, frame: 8_192, rate: 44_100))
        _ = capture.detachForBoundary(successor: { buffer, time in
            delivered.successorFrames += Int(buffer.frameLength)
            return successor.enqueuePCMBuffer(buffer, presentationTime: time)
        }, admissionGate: nil)
        capture._resumeProcessingForTesting()
        try await withTimeout(seconds: 5) { await capture.drain() }
        #expect(delivered.originalCalls >= 2)
        #expect(delivered.originalFrames > 256)
        #expect(delivered.successorFrames == 0)
        let kept = writer.statisticsSnapshot.acceptedFrames
        #expect(kept > accepted)

        let later = try markedBuffer(channels: 1, frames: 128, rate: 48_000) { _, _ in 0.3 }
        capture._enqueueForTesting(later, targetFormat: target, when: hostAudioTime(host, frame: 20_000, rate: 48_000))
        try await withTimeout(seconds: 5) { await capture.drain() }
        #expect(delivered.successorFrames > 0)
        #expect(writer.statisticsSnapshot.acceptedFrames == kept)
        _ = await writer.finish()
        _ = await successor.finish()
    }

    // 8. Native render failure, no delivery after stop, recovery through seam
    @Test func nativeRenderFailureNoDeliveryAfterStopRecoveryThroughSeam() throws {
        let fakeUnit = FakeMicrophoneInputUnit(sampleRate: 48000, channelCount: 1)
        let engine = NativeMicrophoneCaptureEngine(unitFactory: { fakeUnit })

        final class CounterBox: @unchecked Sendable {
            var count = 0
        }
        let hookFired = CounterBox()
        engine.setRenderFailureHook {
            hookFired.count += 1
        }

        final class BoolBox: @unchecked Sendable {
            var value = false
        }
        let delivered = BoolBox()
        try engine.start(deviceID: 10, deviceName: "fake-mic") { _, _ in
            delivered.value = true
        }

        let renderProc = try #require(fakeUnit.renderCallback)
        let refCon = try #require(fakeUnit.renderRefCon)

        var flags: AudioUnitRenderActionFlags = []
        var ts = AudioTimeStamp()
        ts.mHostTime = mach_absolute_time()
        var bufList = AudioBufferList()

        // 1. Two failed renders from AUHAL fire the failure hook once and deliver no PCM
        fakeUnit.renderStatus = -1
        let status1 = renderProc(refCon, &flags, &ts, 1, 512, &bufList)
        #expect(status1 != noErr)
        #expect(!delivered.value)
        #expect(hookFired.count == 1)

        fakeUnit.renderStatus = -2
        let status2 = renderProc(refCon, &flags, &ts, 1, 512, &bufList)
        #expect(status2 != noErr)
        #expect(!delivered.value)
        #expect(hookFired.count == 1) // Hook fires once for two failed renders

        #expect(engine.takeRenderFailure() == true)

        // 2. Frame count above buffer capacity is the same failure (fires hook again after takeRenderFailure)
        fakeUnit.renderStatus = noErr
        let oversizedStatus = renderProc(refCon, &flags, &ts, 1, 8192, &bufList)
        #expect(oversizedStatus != noErr)
        #expect(!delivered.value)
        #expect(hookFired.count == 2)
        #expect(engine.takeRenderFailure() == true)

        // The callback runs from stop while the owner is still retained, before dispose.
        delivered.value = false
        fakeUnit.renderStatus = noErr
        fakeUnit.invokeCallbackOnStop = true
        engine.stop()
        #expect(!delivered.value)
        #expect(fakeUnit.disposeCallCount == 1)

        // Recover on a new owner. Do not call the disposed refcon.
        try engine.start(deviceID: 10, deviceName: "fake-mic") { _, _ in
            delivered.value = true
        }
        let recoveredStatus = invokeRender(fakeUnit, frames: 512)
        #expect(recoveredStatus == noErr)
        #expect(delivered.value)
    }

    // 8b. unit.render blocks and stop does not dispose until that render returns
    @Test func unitRenderBlocksAndStopDoesNotDisposeUntilRenderReturns() throws {
        let fakeUnit = FakeMicrophoneInputUnit(sampleRate: 48000, channelCount: 1)
        let engine = NativeMicrophoneCaptureEngine(unitFactory: { fakeUnit })

        let renderStarted = DispatchSemaphore(value: 0)
        let renderBlock = DispatchSemaphore(value: 0)
        fakeUnit.onRender = {
            renderStarted.signal()
            renderBlock.wait()
        }

        try engine.start(deviceID: 10, deviceName: "fake-mic") { _, _ in }
        let renderProc = try #require(fakeUnit.renderCallback)
        let refCon = try #require(fakeUnit.renderRefCon)
        let refConInt = UInt(bitPattern: refCon)

        let renderDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var flags: AudioUnitRenderActionFlags = []
            var ts = AudioTimeStamp()
            ts.mHostTime = mach_absolute_time()
            var bufList = AudioBufferList()
            let ptr = UnsafeMutableRawPointer(bitPattern: refConInt)!
            _ = renderProc(ptr, &flags, &ts, 1, 512, &bufList)
            renderDone.signal()
        }

        renderStarted.wait()

        let stopDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            engine.stop()
            stopDone.signal()
        }

        Thread.sleep(forTimeInterval: 0.05)
        #expect(fakeUnit.disposeCallCount == 0)

        renderBlock.signal()
        renderDone.wait()
        stopDone.wait()

        #expect(fakeUnit.disposeCallCount == 1)
    }

    // 9. An old queued failure hook must not consume the replacement engine's failure.
    @Test func queuedOldRenderFailureDoesNotConsumeTheReplacementFailure() async throws {
        defer { microphoneNativeResetOwnersForTesting() }
        let root = try makeTempDirectory("mic-failure-fence")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = mach_absolute_time()
        let uid = "fence-\(UUID().uuidString)"
        let engines = EngineBox(uid: uid)
        let device = AudioInputDevice(id: 10, name: "mic", uid: uid, manufacturer: nil, sampleRate: 48_000, transportType: .usb)
        let capture = ExternalMicCapture(
            device: device, gain: 1,
            engineFactory: { engines.make() },
            resolveDeviceID: { _ in 10 },
            layoutReader: { _ in testOneChannelLayout }
        )
        defer { capture.stop() }
        let writer = try SingleTrackAudioWriter(
            url: root.appendingPathComponent("source.m4a"),
            trackType: .microphone(name: device.name, deviceUID: device.uid),
            segmentStartTime: CMClockMakeHostTimeFromSystemUnits(host)
        )
        let seen = ErrorBox()
        capture.setQueuedCallbacks(
            audio: { _, _ in nil },
            error: { error in
                seen.errors.append(error)
                writer.reportCaptureFailure(error)
            },
            rawError: { error in
                seen.errors.append(error)
                writer.reportCaptureFailure(error)
            },
            admissionGate: nil
        )
        try capture.start()
        let first = try #require(engines.fakes.first)
        var rearmError: Error?
        capture._onWriterQueueForTesting {
            first.renderStatus = -1
            _ = invokeRender(first, frames: 512)
            do { try capture._rearmForTesting() } catch { rearmError = error }
            guard let second = engines.fakes.last, second !== first else { return }
            second.renderStatus = -1
            _ = invokeRender(second, frames: 512)
        }
        capture._onWriterQueueForTesting {}
        #expect(rearmError == nil)
        #expect(seen.errors.count == 1)
        if case ExternalMicCapture.ExternalMicCaptureError.renderFailed = seen.errors[0] {
        } else {
            Issue.record("expected renderFailed, got \(seen.errors)")
        }
        let stats = writer.statisticsSnapshot
        #expect(stats.failures.count == 1)
        #expect(stats.failures.first?.stage == "capture")
        #expect(stats.failures.first?.count == 1)
        #expect(stats.statisticsComplete == false)
        _ = await writer.finish()
    }

    // 10. Repeated failed dispose stays within one parked unit plus one live unit
    @Test func repeatedFailedDisposeStaysWithinParkedBound() throws {
        defer { microphoneNativeResetOwnersForTesting() }
        let fakeUnit1 = FakeMicrophoneInputUnit(sampleRate: 48000, channelCount: 1)
        fakeUnit1.disposeStatus = -1 // Dispose fails

        let fakeUnit2 = FakeMicrophoneInputUnit(sampleRate: 48000, channelCount: 1)

        final class SequenceFactory: @unchecked Sendable {
            let units: [FakeMicrophoneInputUnit]
            var index = 0
            init(units: [FakeMicrophoneInputUnit]) { self.units = units }
            func next() -> any MicrophoneInputUnit {
                let u = units[min(index, units.count - 1)]
                index += 1
                return u
            }
        }
        let factory = SequenceFactory(units: [fakeUnit1, fakeUnit2])
        let engine = NativeMicrophoneCaptureEngine(unitFactory: { factory.next() })

        try engine.start(deviceID: 10, deviceName: "mic-1") { _, _ in }
        engine.stop() // unit 1 parked because dispose failed (-1)
        #expect(fakeUnit1.disposeCallCount == 1)

        // Attempting to start unit 2 while unit 1 still cannot dispose throws failedToDisposeParkedUnit
        #expect(throws: ExternalMicCapture.ExternalMicCaptureError.self) {
            try engine.start(deviceID: 10, deviceName: "mic-2") { _, _ in }
        }
        #expect(fakeUnit1.disposeCallCount == 2)

        // Once unit 1 can dispose, start succeeds and creates live unit 2
        fakeUnit1.disposeStatus = noErr
        try engine.start(deviceID: 10, deviceName: "mic-2") { _, _ in }
        #expect(fakeUnit1.disposeCallCount == 3)
        engine.stop()
    }

    @Test func failedNativeOwnershipBlocksSameUIDReplacementUntilReclaim() throws {
        defer { microphoneNativeResetOwnersForTesting() }
        let uid = "park-\(UUID().uuidString)"
        let opened = FakeMicrophoneInputUnit()
        opened.openStatus = -50
        opened.disposeStatus = -1
        let firstBuilds = IntBox()
        let engineA = NativeMicrophoneCaptureEngine(unitFactory: { firstBuilds.value += 1; return opened })
        engineA.setNativeOwnerKey(uid)
        #expect(throws: ExternalMicCapture.ExternalMicCaptureError.self) {
            try engineA.start(deviceID: 10, deviceName: "early") { _, _ in }
        }
        #expect(firstBuilds.value == 1)
        #expect(opened.disposeCallCount == 1)
        #expect(microphoneNativeUnresolvedCount(uid) == 1)

        let secondBuilds = IntBox()
        let replacement = FakeMicrophoneInputUnit()
        let engineB = NativeMicrophoneCaptureEngine(unitFactory: { secondBuilds.value += 1; return replacement })
        engineB.setNativeOwnerKey(uid)
        #expect(throws: ExternalMicCapture.ExternalMicCaptureError.self) {
            try engineB.start(deviceID: 10, deviceName: "blocked") { _, _ in }
        }
        #expect(secondBuilds.value == 0)
        #expect(opened.disposeCallCount == 2)
        #expect(microphoneNativeUnresolvedCount(uid) == 1)

        opened.disposeStatus = noErr
        try engineB.start(deviceID: 10, deviceName: "reclaimed") { _, _ in }
        #expect(secondBuilds.value == 1)
        #expect(opened.disposeCallCount == 3)
        #expect(microphoneNativeUnresolvedCount(uid) == 0)
        engineB.stop()

        let uninitialized = FakeMicrophoneInputUnit()
        uninitialized.uninitializeStatus = -1
        let uid2 = "uninit-\(UUID().uuidString)"
        let live = NativeMicrophoneCaptureEngine(unitFactory: { uninitialized })
        live.setNativeOwnerKey(uid2)
        try live.start(deviceID: 10, deviceName: "live") { _, _ in }
        live.stop()
        #expect(uninitialized.disposeCallCount == 0)
        #expect(microphoneNativeUnresolvedCount(uid2) == 1)
        let thirdBuilds = IntBox()
        let nextUnit = FakeMicrophoneInputUnit()
        let next = NativeMicrophoneCaptureEngine(unitFactory: { thirdBuilds.value += 1; return nextUnit })
        next.setNativeOwnerKey(uid2)
        #expect(throws: ExternalMicCapture.ExternalMicCaptureError.self) {
            try next.start(deviceID: 10, deviceName: "still-parked") { _, _ in }
        }
        #expect(thirdBuilds.value == 0)
        uninitialized.uninitializeStatus = noErr
        try next.start(deviceID: 10, deviceName: "free") { _, _ in }
        #expect(thirdBuilds.value == 1)
        #expect(uninitialized.disposeCallCount == 1)
        next.stop()

        let clean = FakeMicrophoneInputUnit()
        clean.openStatus = -1
        let uid3 = "clean-\(UUID().uuidString)"
        let failedOpen = NativeMicrophoneCaptureEngine(unitFactory: { clean })
        failedOpen.setNativeOwnerKey(uid3)
        #expect(throws: ExternalMicCapture.ExternalMicCaptureError.self) {
            try failedOpen.start(deviceID: 10, deviceName: "open") { _, _ in }
        }
        #expect(microphoneNativeUnresolvedCount(uid3) == 0)
        let fourthBuilds = IntBox()
        let after = NativeMicrophoneCaptureEngine(unitFactory: { fourthBuilds.value += 1; return FakeMicrophoneInputUnit() })
        after.setNativeOwnerKey(uid3)
        try after.start(deviceID: 10, deviceName: "after-clean-failure") { _, _ in }
        #expect(fourthBuilds.value == 1)
        after.stop()
    }

    @Test func startupCallbackAndBlockedRenderReleaseNothingEarly() throws {
        defer { microphoneNativeResetOwnersForTesting() }
        let uid = "startup-\(UUID().uuidString)"
        let denied = FakeMicrophoneInputUnit()
        denied.invokeCallbackOnStart = true
        denied.startStatus = -4
        let delivered = IntBox()
        let engine = NativeMicrophoneCaptureEngine(unitFactory: { denied })
        engine.setNativeOwnerKey(uid)
        #expect(throws: ExternalMicCapture.ExternalMicCaptureError.self) {
            try engine.start(deviceID: 10, deviceName: "start-fails") { _, _ in delivered.value += 1 }
        }
        #expect(delivered.value == 0)
        #expect(denied.renderCallCount == 0)
        #expect(microphoneNativeUnresolvedCount(uid) == 0)

        let mismatched = FakeMicrophoneInputUnit()
        mismatched.invokeCallbackOnStart = true
        mismatched.clientFormatByteSize = 3
        let formatEngine = NativeMicrophoneCaptureEngine(unitFactory: { mismatched })
        formatEngine.setNativeOwnerKey(uid)
        #expect(throws: ExternalMicCapture.ExternalMicCaptureError.self) {
            try formatEngine.start(deviceID: 10, deviceName: "format") { _, _ in delivered.value += 1 }
        }
        #expect(delivered.value == 0)

        let unbound = FakeMicrophoneInputUnit()
        unbound.boundDeviceReadback = 99
        let bindEngine = NativeMicrophoneCaptureEngine(unitFactory: { unbound })
        bindEngine.setNativeOwnerKey(uid)
        #expect(throws: ExternalMicCapture.ExternalMicCaptureError.self) {
            try bindEngine.start(deviceID: 10, deviceName: "bind") { _, _ in delivered.value += 1 }
        }
        #expect(delivered.value == 0)

        let reentered = FakeMicrophoneInputUnit()
        reentered.reenterOnRender = true
        reentered.nestedFrameCount = 32
        let renderedFrames = IntBox()
        let reenterEngine = NativeMicrophoneCaptureEngine(unitFactory: { reentered })
        try reenterEngine.start(deviceID: 10, deviceName: "reenter") { buffer, _ in
            renderedFrames.value = Int(buffer.frameLength)
        }
        #expect(invokeRender(reentered, frames: 128) == noErr)
        #expect(reentered.nestedStatus != noErr)
        #expect(renderedFrames.value == 128)
        #expect(reentered.renderCallCount == 1)
        reenterEngine.stop()

        let blocked = FakeMicrophoneInputUnit()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        blocked.onRender = {
            entered.signal()
            release.wait()
        }
        let blockEngine = NativeMicrophoneCaptureEngine(unitFactory: { blocked })
        try blockEngine.start(deviceID: 10, deviceName: "busy") { buffer, _ in
            renderedFrames.value = Int(buffer.frameLength)
        }
        let callback = try #require(blocked.renderCallback)
        let refCon = UInt(bitPattern: try #require(blocked.renderRefCon))
        Thread.detachNewThread {
            var flags: AudioUnitRenderActionFlags = []
            var time = AudioTimeStamp()
            time.mHostTime = mach_absolute_time()
            var list = AudioBufferList()
            _ = callback(UnsafeMutableRawPointer(bitPattern: refCon)!, &flags, &time, 1, 128, &list)
        }
        #expect(entered.wait(timeout: .now() + 2) == .success)
        let secondDone = DispatchSemaphore(value: 0)
        let secondStatus = StatusBox()
        Thread.detachNewThread {
            var flags: AudioUnitRenderActionFlags = []
            var time = AudioTimeStamp()
            time.mHostTime = mach_absolute_time()
            var list = AudioBufferList()
            secondStatus.value = callback(UnsafeMutableRawPointer(bitPattern: refCon)!, &flags, &time, 1, 64, &list)
            secondDone.signal()
        }
        #expect(secondDone.wait(timeout: .now() + 2) == .success)
        #expect(secondStatus.value != noErr)
        release.signal()
        Thread.sleep(forTimeInterval: 0.05)
        #expect(renderedFrames.value == 128)
        blockEngine.stop()

        let hookUnit = FakeMicrophoneInputUnit()
        let hookEntered = DispatchSemaphore(value: 0)
        let hookRelease = DispatchSemaphore(value: 0)
        let hookEngine = NativeMicrophoneCaptureEngine(unitFactory: { hookUnit })
        hookEngine.setRenderFailureHook {
            hookEntered.signal()
            hookRelease.wait()
        }
        try hookEngine.start(deviceID: 10, deviceName: "hook") { _, _ in }
        hookUnit.renderStatus = -1
        Thread.detachNewThread { _ = invokeRender(hookUnit, frames: 512) }
        #expect(hookEntered.wait(timeout: .now() + 2) == .success)
        let stopDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            hookEngine.stop()
            stopDone.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)
        #expect(hookUnit.disposeCallCount == 0)
        hookRelease.signal()
        #expect(stopDone.wait(timeout: .now() + 2) == .success)
        #expect(hookUnit.disposeCallCount == 1)
    }

    @Test func choiceLifecycleKeepsAcceptedMediaAndDoesNotResurrectAClearedInput() async throws {
        defer { microphoneNativeResetOwnersForTesting() }
        let root = try makeTempDirectory("mic-choice-life")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = mach_absolute_time()
        let ifaceUID = "iface-\(UUID().uuidString)"
        let siblingUID = "sib-\(UUID().uuidString)"
        let iface = AudioInputDevice(id: 10, name: "iface", uid: ifaceUID, manufacturer: nil, sampleRate: 48_000, transportType: .usb)
        let sibling = AudioInputDevice(id: 11, name: "sibling", uid: siblingUID, manufacturer: nil, sampleRate: 48_000, transportType: .usb)
        let ten = micLayout(channels: 10)
        guard case .available(let layout) = ten else { Issue.record("layout"); return }
        let layouts = LayoutBox(ten)
        let manager = MicrophoneCaptureManager(gain: 1, captureFactory: { device, gain, verbose in
            ExternalMicCapture(
                device: device, gain: gain, verbose: verbose,
                engineFactory: { NativeMicrophoneCaptureEngine(unitFactory: { FakeMicrophoneInputUnit() }) },
                resolveDeviceID: { _ in device.id },
                layoutReader: { id in id == iface.id ? layouts.value : testOneChannelLayout }
            )
        })
        manager.updateSelection([iface, sibling])
        #expect(throws: ExternalMicCapture.ExternalMicCaptureError.self) {
            try manager.startCapture(for: iface)
        }
        let choiceA = MicrophoneChoice(ordinal: 0, fingerprint: layout.fingerprint)
        let choiceB = MicrophoneChoice(ordinal: 4, fingerprint: layout.fingerprint)
        try manager.startCapture(for: iface, choice: choiceA)
        try manager.startCapture(for: sibling)
        let ifaceCapture = try #require(manager.getCapture(for: iface.uid))
        let siblingCapture = try #require(manager.getCapture(for: sibling.uid))
        let ifaceWriter = try SingleTrackAudioWriter(
            url: root.appendingPathComponent("iface.m4a"),
            trackType: .microphone(name: iface.name, deviceUID: iface.uid),
            segmentStartTime: CMClockMakeHostTimeFromSystemUnits(host)
        )
        let siblingWriter = try SingleTrackAudioWriter(
            url: root.appendingPathComponent("sibling.m4a"),
            trackType: .microphone(name: sibling.name, deviceUID: sibling.uid),
            segmentStartTime: CMClockMakeHostTimeFromSystemUnits(host)
        )
        let ifaceSamples = SampleBox()
        let siblingSamples = SampleBox()
        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        manager.setQueuedCallback(for: iface.uid, callback: { buffer, time in
            ifaceSamples.append(buffer)
            return ifaceWriter.enqueuePCMBuffer(buffer, presentationTime: time)
        }, onError: { ifaceWriter.reportCaptureFailure($0) })
        manager.setQueuedCallback(for: sibling.uid, callback: { buffer, time in
            siblingSamples.append(buffer)
            return siblingWriter.enqueuePCMBuffer(buffer, presentationTime: time)
        }, onError: { siblingWriter.reportCaptureFailure($0) })

        let markedA = try markedBuffer(channels: 10, frames: 64, rate: 48_000) { channel, _ in channel == 0 ? 0.25 : 0.9 }
        ifaceCapture._enqueueForTesting(markedA, targetFormat: target, when: hostAudioTime(host, frame: 0, rate: 48_000))
        let siblingTone = try markedBuffer(channels: 1, frames: 64, rate: 48_000) { _, _ in 0.15 }
        siblingCapture._enqueueForTesting(siblingTone, targetFormat: target, when: hostAudioTime(host, frame: 0, rate: 48_000))
        try await withTimeout(seconds: 5) { await ifaceCapture.drain() }
        try await withTimeout(seconds: 5) { await siblingCapture.drain() }
        #expect(ifaceSamples.values.count == 64)
        #expect(abs(ifaceSamples.values.reduce(0, +) / 64 - 0.25) < 0.001)
        let acceptedA = ifaceWriter.statisticsSnapshot.acceptedFrames
        #expect(acceptedA >= 64)
        let siblingAccepted = siblingWriter.statisticsSnapshot.acceptedFrames
        #expect(siblingAccepted >= 64)

        manager.setSavedChoice(for: iface.uid, choice: choiceB)
        #expect(manager.authorizeChoice(for: iface.uid, choice: choiceB))
        let markedB = try markedBuffer(channels: 10, frames: 64, rate: 48_000) { channel, _ in channel == 4 ? 0.55 : 0.9 }
        ifaceCapture._enqueueForTesting(markedB, targetFormat: target, when: hostAudioTime(host, frame: 4_096, rate: 48_000))
        try await withTimeout(seconds: 5) { await ifaceCapture.drain() }
        let choiceBSamples = ifaceSamples.values.dropFirst(64)
        #expect(choiceBSamples.count == 64)
        #expect(abs(choiceBSamples.reduce(0, +) / 64 - 0.55) < 0.001)
        let acceptedB = ifaceWriter.statisticsSnapshot.acceptedFrames
        #expect(acceptedB > acceptedA)

        manager.setSavedChoice(for: iface.uid, choice: nil)
        #expect(manager.authorizeChoice(for: iface.uid, choice: nil) == false)
        let copies = IntBox()
        ifaceCapture._willCopyPCMForTesting = { copies.value += 1 }
        let afterClear = ifaceSamples.values.count
        ifaceCapture._enqueueForTesting(markedA, targetFormat: target, when: hostAudioTime(host, frame: 8_192, rate: 48_000))
        _ = ifaceCapture.detachForBoundary(successor: { buffer, time in
            ifaceSamples.append(buffer)
            return ifaceWriter.enqueuePCMBuffer(buffer, presentationTime: time)
        }, admissionGate: nil)
        try await withTimeout(seconds: 5) { await ifaceCapture.drain() }
        #expect(copies.value == 0)
        #expect(ifaceSamples.values.count == afterClear)
        #expect(ifaceWriter.statisticsSnapshot.acceptedFrames == acceptedB)

        manager.stopCapture(deviceUID: iface.uid)
        #expect(throws: ExternalMicCapture.ExternalMicCaptureError.self) {
            try manager.startCapture(for: iface)
        }
        siblingCapture._enqueueForTesting(siblingTone, targetFormat: target, when: hostAudioTime(host, frame: 8_192, rate: 48_000))
        try await withTimeout(seconds: 5) { await siblingCapture.drain() }
        #expect(siblingWriter.statisticsSnapshot.acceptedFrames > siblingAccepted)
        siblingCapture.stop()
        _ = await ifaceWriter.finish()
        _ = await siblingWriter.finish()
    }

    @Test func layoutDriftAndAggregateIdentityDoNotFallBackToAnotherInput() async throws {
        defer { microphoneNativeResetOwnersForTesting() }
        let full = [aggregateMember("sub-1", 2), aggregateMember("sub-2", 2)]
        let active = [aggregateMember("sub-1", 2), aggregateMember("sub-2", 2)]
        let swapped = [aggregateMember("sub-2", 2), aggregateMember("sub-1", 2)]
        let substituted = [aggregateMember("sub-2", 2)]
        let ten = micLayout(channels: 10)
        let two = micLayout(channels: 2)
        let aggregate = micLayout(channels: 4, members: full, active: active)
        let reordered = micLayout(channels: 4, members: swapped, active: swapped)
        let replacedActive = micLayout(channels: 4, members: full, active: substituted)
        guard case .available(let tenLayout) = ten, case .available(let aggregateLayout) = aggregate else {
            Issue.record("layouts"); return
        }
        let device = AudioInputDevice(id: 10, name: "agg", uid: "agg", manufacturer: nil, sampleRate: 48_000, transportType: .aggregate)
        let fresh = AudioInputDevice(id: 90, name: "agg", uid: "agg", manufacturer: nil, sampleRate: 96_000, transportType: .aggregate)
        let tenChoice = MicrophoneChoice(ordinal: 7, fingerprint: tenLayout.fingerprint)
        let aggregateChoice = MicrophoneChoice(ordinal: 1, fingerprint: aggregateLayout.fingerprint)
        #expect(classifyMicrophone(device: device, choice: tenChoice, layoutResult: two) != .admitted)
        #expect(classifyMicrophone(device: device, choice: aggregateChoice, layoutResult: aggregate) == .admitted)
        #expect(classifyMicrophone(device: fresh, choice: aggregateChoice, layoutResult: aggregate) == .admitted)
        #expect(classifyMicrophone(device: fresh, choice: aggregateChoice, layoutResult: reordered) != .admitted)
        #expect(classifyMicrophone(device: fresh, choice: aggregateChoice, layoutResult: replacedActive) != .admitted)

        let savedWithoutActive = """
        {"streams":[{"startingChannel":1,"channelCount":4}],"aggregateMembers":[{"uid":"sub-1","inputChannelCount":2},{"uid":"sub-2","inputChannelCount":2}]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MicrophoneLayoutFingerprint.self, from: savedWithoutActive)
        #expect(decoded.activeMembers == nil)
        #expect(decoded == MicrophoneLayoutFingerprint(streams: decoded.streams, aggregateMembers: decoded.aggregateMembers, activeMembers: nil))
        #expect(decoded != aggregateLayout.fingerprint)

        #expect(readInjectedLayout(channels: 4, membership: .unavailable) == .unavailable)
        #expect(readInjectedLayout(channels: 4, membership: .members(full: full, active: active), nested: { $0 == "sub-2" }) == .unavailable)
        #expect(readInjectedLayout(channels: 10, membership: .members(full: full, active: active)) == .unavailable)
        #expect(readInjectedLayout(channels: 4, membership: .members(full: [aggregateMember("dup", 2), aggregateMember("dup", 2)], active: [])) == .unavailable)
        #expect(readInjectedLayout(channels: 2, membership: .members(full: [aggregateMember("only", 2)], active: [aggregateMember("missing", 2)])) == .unavailable)
        let tooMany = (0..<33).map { aggregateMember("m\($0)", 1) }
        #expect(readInjectedLayout(channels: 33, membership: .members(full: tooMany, active: [])) == .unavailable)
        let zeroMember = readInjectedLayout(channels: 2, membership: .members(full: [aggregateMember("a", 2), aggregateMember("b", 0)], active: [aggregateMember("a", 2)]))
        guard case .available(let zeroLayout) = zeroMember else { Issue.record("zero member"); return }
        #expect(zeroLayout.fingerprint.aggregateMembers?.count == 2)
        let ordinary = readInjectedLayout(channels: 1, membership: .notAggregate)
        guard case .available(let ordinaryLayout) = ordinary else { Issue.record("ordinary"); return }
        #expect(ordinaryLayout.fingerprint.aggregateMembers == nil)
        #expect(ordinaryLayout.fingerprint.activeMembers == nil)
        #expect(classifyMicrophone(device: device, choice: nil, layoutResult: ordinary) == .admitted)

        let liveLayout = LayoutBox(ten)
        let recovery = IntBox()
        let failures = IntBox()
        let uid = "drift-\(UUID().uuidString)"
        let liveDevice = AudioInputDevice(id: 15, name: "live", uid: uid, manufacturer: nil, sampleRate: 48_000, transportType: .usb)
        let capture = ExternalMicCapture(
            device: liveDevice, gain: 1,
            engineFactory: { NativeMicrophoneCaptureEngine(unitFactory: { FakeMicrophoneInputUnit() }) },
            resolveDeviceID: { _ in 15 },
            layoutReader: { _ in liveLayout.value }
        )
        defer { capture.stop() }
        capture.onRecoveryNeeded = { recovery.value += 1 }
        capture.onCaptureError = { _ in failures.value += 1 }
        #expect(capture.authorizeChoice(tenChoice))
        try capture.start()
        liveLayout.value = two
        capture.triggerRecoveryCheck()
        try await withTimeout(seconds: 5) { await capture.drain() }
        capture._onWriterQueueForTesting {}
        #expect(recovery.value == 0)
        #expect(failures.value == 0)
        #expect(!capture.isCapturing)
        let copies = IntBox()
        capture._willCopyPCMForTesting = { copies.value += 1 }
        let stereo = try markedBuffer(channels: 2, frames: 32, rate: 48_000) { _, _ in 0.8 }
        capture._enqueueForTesting(stereo)
        #expect(copies.value == 0)

        liveLayout.value = aggregate
        let reorderCapture = ExternalMicCapture(
            device: liveDevice, gain: 1,
            engineFactory: { NativeMicrophoneCaptureEngine(unitFactory: { FakeMicrophoneInputUnit() }) },
            resolveDeviceID: { _ in 15 },
            layoutReader: { _ in liveLayout.value }
        )
        defer { reorderCapture.stop() }
        reorderCapture.onRecoveryNeeded = { recovery.value += 1 }
        #expect(reorderCapture.authorizeChoice(aggregateChoice))
        try reorderCapture.start()
        liveLayout.value = reordered
        reorderCapture.triggerRecoveryCheck()
        try await withTimeout(seconds: 5) { await reorderCapture.drain() }
        #expect(recovery.value == 0)
        #expect(!reorderCapture.isCapturing)

        let usable = ExternalMicCapture(
            device: fresh, gain: 1,
            engineFactory: { NativeMicrophoneCaptureEngine(unitFactory: { FakeMicrophoneInputUnit() }) },
            resolveDeviceID: { _ in 90 },
            layoutReader: { _ in aggregate }
        )
        defer { usable.stop() }
        let heard = SampleBox()
        #expect(usable.authorizeChoice(aggregateChoice))
        try usable.start()
        usable.setCallbacks(audio: { buffer, _ in heard.append(buffer) }, error: { _ in })
        let marked = try markedBuffer(channels: 4, frames: 16, rate: 48_000) { channel, _ in channel == 1 ? 0.4 : 0.9 }
        let mono = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        usable._enqueueForTesting(marked, targetFormat: mono)
        try await withTimeout(seconds: 5) { await usable.drain() }
        #expect(heard.values.count == 16)
        #expect(abs(heard.values.reduce(0, +) / 16 - 0.4) < 0.001)

        let resolved = IDBox(21)
        let deviceLossRecovery = IntBox()
        let lossUID = "loss-\(UUID().uuidString)"
        let loss = ExternalMicCapture(
            device: AudioInputDevice(id: 21, name: "loss", uid: lossUID, manufacturer: nil, sampleRate: 48_000, transportType: .usb),
            gain: 1,
            engineFactory: { NativeMicrophoneCaptureEngine(unitFactory: { FakeMicrophoneInputUnit() }) },
            resolveDeviceID: { _ in resolved.value },
            layoutReader: { _ in testOneChannelLayout }
        )
        defer { loss.stop() }
        loss.onRecoveryNeeded = { deviceLossRecovery.value += 1 }
        try loss.start()
        resolved.value = nil
        loss.triggerRecoveryCheck()
        try await withTimeout(seconds: 5) { await loss.drain() }
        #expect(deviceLossRecovery.value == 1)
        #expect(!loss.isCapturing)
    }

    @Test func aggregateListChangeStopsTheOldOrdinalBeforeAnotherBuffer() async throws {
        defer { microphoneNativeResetOwnersForTesting() }
        let full = [aggregateMember("sub-1", 2), aggregateMember("sub-2", 2)]
        let reversed = [aggregateMember("sub-2", 2), aggregateMember("sub-1", 2)]
        let original = micLayout(channels: 4, members: full, active: full)
        let reordered = micLayout(channels: 4, members: reversed, active: reversed)
        guard case .available(let originalLayout) = original else { Issue.record("layout"); return }
        let live = LayoutBox(original)
        let uid = "agg-listen-\(UUID().uuidString)"
        let capture = ExternalMicCapture(
            device: AudioInputDevice(id: 0x7FFF_FF10, name: "agg", uid: uid, manufacturer: nil, sampleRate: 48_000, transportType: .aggregate),
            gain: 1,
            engineFactory: { NativeMicrophoneCaptureEngine(unitFactory: { FakeMicrophoneInputUnit() }) },
            resolveDeviceID: { _ in 0x7FFF_FF10 },
            layoutReader: { _ in live.value }
        )
        defer { capture.stop() }
        let recovery = IntBox()
        let failures = IntBox()
        capture.onRecoveryNeeded = { recovery.value += 1 }
        capture.setCallbacks(audio: { _, _ in }, error: { error in
            failures.value += 1
            Issue.record("capture error \(String(describing: error))")
        })
        #expect(capture.authorizeChoice(MicrophoneChoice(ordinal: 0, fingerprint: originalLayout.fingerprint)))
        try capture.start()
        #expect(capture.deviceListenerSelectorsForTesting.contains(kAudioAggregateDevicePropertyFullSubDeviceList))
        #expect(capture.deviceListenerSelectorsForTesting.contains(kAudioAggregateDevicePropertyActiveSubDeviceList))
        let copies = IntBox()
        capture._willCopyPCMForTesting = { copies.value += 1 }
        let buffer = try markedBuffer(channels: 4, frames: 32, rate: 48_000) { channel, _ in channel == 0 ? 0.4 : 0.1 }
        let mono = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        capture._enqueueForTesting(buffer, targetFormat: mono)
        #expect(copies.value == 1)
        try await withTimeout(seconds: 5) { await capture.drain() }
        #expect(failures.value == 0)

        capture._suspendProcessingForTesting()
        capture.simulateDevicePropertyChangeForTesting(kAudioAggregateDevicePropertyActiveSubDeviceList)
        try await withTimeout(seconds: 2) {
            while capture._recordingEnabledForTesting { try await Task.sleep(for: .milliseconds(5)) }
        }
        capture._enqueueForTesting(buffer, targetFormat: mono)
        #expect(copies.value == 1)
        capture._resumeProcessingForTesting()
        try await withTimeout(seconds: 5) { await capture.drain() }
        capture._onWriterQueueForTesting {}
        #expect(capture.isCapturing)
        #expect(capture._recordingEnabledForTesting)
        #expect(copies.value == 1)
        #expect(recovery.value == 0)
        #expect(failures.value == 0)

        capture._suspendProcessingForTesting()
        live.value = reordered
        capture.simulateDevicePropertyChangeForTesting(kAudioAggregateDevicePropertyFullSubDeviceList)
        try await withTimeout(seconds: 2) {
            while capture._recordingEnabledForTesting { try await Task.sleep(for: .milliseconds(5)) }
        }
        capture._enqueueForTesting(buffer, targetFormat: mono)
        #expect(copies.value == 1)
        capture._resumeProcessingForTesting()
        try await withTimeout(seconds: 5) { await capture.drain() }
        capture._onWriterQueueForTesting {}
        #expect(!capture.isCapturing)
        #expect(recovery.value == 0)
        #expect(failures.value == 0)
        capture._enqueueForTesting(buffer, targetFormat: mono)
        #expect(copies.value == 1)

        let usb = ExternalMicCapture(
            device: AudioInputDevice(id: 0x7FFF_FF11, name: "usb", uid: "usb-listen-\(UUID().uuidString)", manufacturer: nil, sampleRate: 48_000, transportType: .usb),
            gain: 1,
            engineFactory: { NativeMicrophoneCaptureEngine(unitFactory: { FakeMicrophoneInputUnit() }) },
            resolveDeviceID: { _ in 0x7FFF_FF11 },
            layoutReader: { _ in testOneChannelLayout }
        )
        defer { usb.stop() }
        try usb.start()
        #expect(!usb.deviceListenerSelectorsForTesting.contains(kAudioAggregateDevicePropertyFullSubDeviceList))
        #expect(!usb.deviceListenerSelectorsForTesting.contains(kAudioAggregateDevicePropertyActiveSubDeviceList))
    }

    @Test func budgetSaturationAndRevocationCopyNothingAndErrorCanReenter() throws {
        let uid = "budget-\(UUID().uuidString)"
        let device = AudioInputDevice(id: 1, name: "budget", uid: uid, manufacturer: nil, sampleRate: 48_000, transportType: .usb)
        let capture = ExternalMicCapture(
            device: device, gain: 1,
            engineFactory: { NativeMicrophoneCaptureEngine(unitFactory: { FakeMicrophoneInputUnit() }) },
            resolveDeviceID: { _ in 1 },
            layoutReader: { _ in testOneChannelLayout }
        )
        defer { capture.stop() }
        let copies = IntBox()
        capture._willCopyPCMForTesting = { copies.value += 1 }
        var held: [AudioMediaLease] = []
        defer { held.forEach { $0.release() } }
        for _ in 0..<64 {
            if let lease = capture.mediaBudget.reserve(.raw, bytes: 64, equivalentFrames: 1) {
                held.append(lease)
            }
        }
        #expect(held.count == 64)
        let done = DispatchSemaphore(value: 0)
        let selection = NSLock()
        capture.setQueuedCallbacks(
            audio: { _, _ in nil },
            error: { _ in },
            rawError: { _ in
                selection.lock()
                capture.revokeUnacceptedAudio()
                selection.unlock()
                done.signal()
            },
            admissionGate: { operation in
                selection.lock()
                operation()
                selection.unlock()
                return true
            }
        )
        let buffer = try markedBuffer(channels: 1, frames: 32, rate: 48_000) { _, _ in 0.2 }
        capture._enqueueForTesting(buffer)
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(copies.value == 0)

        capture.revokeUnacceptedAudio()
        capture._enqueueForTesting(buffer)
        #expect(copies.value == 0)
    }

    @MainActor
    @Test func combinedModeAndChoiceSaveFailureRestoresOldPolicy() {
        let fingerprint = MicrophoneLayoutFingerprint(streams: [.init(startingChannel: 1, channelCount: 10)])
        let oldChoice = MicrophoneChoice(ordinal: 1, fingerprint: fingerprint)
        let newChoice = MicrophoneChoice(ordinal: 4, fingerprint: fingerprint)
        let oldEntry = MicrophoneEntry(uid: "iface", name: "Iface", mode: .off, choice: oldChoice)
        var initial = AppConfig()
        initial.microphonePriority = [oldEntry]
        let state = AppState.forLoginItemTest(
            config: initial,
            loginService: FakeLoginItemService(watchdogStatus: .notRegistered, mainAppStatus: .notFound)
        )
        var next = state.config
        let flipped = !state.config.preserveSyncedSegments
        next.preserveSyncedSegments = flipped
        next.microphonePriority = [MicrophoneEntry(uid: "iface", name: "Iface", mode: .always, choice: newChoice)]
        state.configSaver = { _ in throw CocoaError(.fileWriteUnknown) }
        state.updateConfig(next)
        #expect(state.config.preserveSyncedSegments == flipped)
        #expect(state.config.microphonePriority == [oldEntry])
        #expect(state.configSaveError == UICopy.ERROR_SAVE_CONFIG)
    }
}

private final class SampleBox: @unchecked Sendable {
    var values: [Float] = []
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        for index in 0..<Int(buffer.frameLength) { values.append(data[0][index]) }
    }
}

private final class CountBox: @unchecked Sendable {
    var originalCalls = 0
    var originalFrames = 0
    var successorFrames = 0
}

private final class ErrorBox: @unchecked Sendable {
    var errors: [Error] = []
}

private final class StatusBox: @unchecked Sendable {
    var value: OSStatus = noErr
}

private final class IntBox: @unchecked Sendable {
    var value = 0
}

private final class IDBox: @unchecked Sendable {
    var value: AudioDeviceID?
    init(_ value: AudioDeviceID?) { self.value = value }
}

private final class EngineBox: @unchecked Sendable {
    let uid: String
    var fakes: [FakeMicrophoneInputUnit] = []
    init(uid: String) { self.uid = uid }
    func make() -> NativeMicrophoneCaptureEngine {
        let fake = FakeMicrophoneInputUnit()
        fakes.append(fake)
        let engine = NativeMicrophoneCaptureEngine(unitFactory: { fake })
        engine.setNativeOwnerKey(uid)
        return engine
    }
}

private final class LayoutBox: @unchecked Sendable {
    var value: MicrophoneMonitor.MicrophoneLayoutResult
    init(_ value: MicrophoneMonitor.MicrophoneLayoutResult) { self.value = value }
}

@discardableResult
private func invokeRender(_ unit: FakeMicrophoneInputUnit, frames: UInt32) -> OSStatus {
    guard let callback = unit.renderCallback, let refCon = unit.renderRefCon else { return -1 }
    var flags: AudioUnitRenderActionFlags = []
    var time = AudioTimeStamp()
    time.mHostTime = mach_absolute_time()
    var list = AudioBufferList()
    return callback(refCon, &flags, &time, 1, frames, &list)
}

private func hostAudioTime(_ host: UInt64, frame: Int64, rate: Double) -> AVAudioTime {
    AVAudioTime(hostTime: host + AVAudioTime.hostTime(forSeconds: Double(frame) / rate), sampleTime: frame, atRate: rate)
}

private func aggregateMember(_ uid: String, _ channels: Int) -> MicrophoneLayoutFingerprint.AggregateMemberSpan {
    MicrophoneLayoutFingerprint.AggregateMemberSpan(uid: uid, inputChannelCount: channels)
}

private func micLayout(
    channels: Int,
    members: [MicrophoneLayoutFingerprint.AggregateMemberSpan]? = nil,
    active: [MicrophoneLayoutFingerprint.AggregateMemberSpan]? = nil
) -> MicrophoneMonitor.MicrophoneLayoutResult {
    .available(MicrophoneMonitor.MicrophoneLayout(
        fingerprint: MicrophoneLayoutFingerprint(
            streams: [.init(startingChannel: 1, channelCount: channels)],
            aggregateMembers: members,
            activeMembers: active
        ),
        channelCount: channels,
        labels: Array(repeating: nil, count: channels)
    ))
}

private func readInjectedLayout(
    channels: Int,
    membership: MicrophoneMonitor.AggregateMembership,
    nested: ((String) -> Bool)? = nil
) -> MicrophoneMonitor.MicrophoneLayoutResult {
    MicrophoneMonitor.readLayout(
        deviceID: 42,
        queryStreams: { _ in [7] },
        queryStreamSpan: { _ in (startingChannel: 1, channelCount: channels) },
        queryStreamConfigChannels: { _ in channels },
        queryAggregateMembers: { _ in membership },
        queryMemberNested: nested,
        queryChannelLabel: { _, _ in nil }
    )
}

private func markedBuffer(channels: Int, frames: AVAudioFrameCount, rate: Double, fill: (Int, Int) -> Float) throws -> AVAudioPCMBuffer {
    let format: AVAudioFormat
    if channels <= 2 {
        format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels)))
    } else {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)))
        format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout))
    }
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let data = try #require(buffer.floatChannelData)
    for channel in 0..<channels {
        for frame in 0..<Int(frames) { data[channel][frame] = fill(channel, frame) }
    }
    return buffer
}
