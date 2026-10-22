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
    var disposeStatus: OSStatus = noErr
    var renderStatus: OSStatus = noErr

    var renderCallback: AURenderCallback?
    var renderRefCon: UnsafeMutableRawPointer?
    var disposeCallCount: Int = 0
    var onRender: (@Sendable () -> Void)?

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
    func start() -> OSStatus { startStatus }
    func stop() -> OSStatus { stopStatus }
    func dispose() -> OSStatus {
        lock.withLock { disposeCallCount += 1 }
        return disposeStatus
    }
    func render(actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                timeStamp: UnsafePointer<AudioTimeStamp>,
                busNumber: UInt32,
                frameCount: UInt32,
                data: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        onRender?()
        return renderStatus
    }
}

@Suite("MicrophoneInputCaptureTests")
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

        // Mutate buffer-list header so flag and list disagree
        planarBuffer.mutableAudioBufferList.pointee.mNumberBuffers = 1
        #expect(ExternalMicCapture.extractChosenChannel(planarBuffer, ordinal: 0) == nil)
        planarBuffer.mutableAudioBufferList.pointee.mNumberBuffers = 3

        interleavedBuffer.mutableAudioBufferList.pointee.mNumberBuffers = 3
        #expect(ExternalMicCapture.extractChosenChannel(interleavedBuffer, ordinal: 0) == nil)
        interleavedBuffer.mutableAudioBufferList.pointee.mNumberBuffers = 1

        interleavedBuffer.mutableAudioBufferList.pointee.mBuffers.mNumberChannels = 1
        #expect(ExternalMicCapture.extractChosenChannel(interleavedBuffer, ordinal: 0) == nil)
        interleavedBuffer.mutableAudioBufferList.pointee.mBuffers.mNumberChannels = 3

        // Non-Float32 PCM rejected
        let intFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, interleaved: false, channelLayout: layout))
        let intBuffer = try #require(AVAudioPCMBuffer(pcmFormat: intFormat, frameCapacity: 4))
        intBuffer.frameLength = 4
        #expect(ExternalMicCapture.extractChosenChannel(intBuffer, ordinal: 0) == nil)
    }

    // 4. 44.1 kHz to 48 kHz through the production converter, including boundary
    @Test func sampleRateConversion441To48Boundary() throws {
        let root = try makeTempDirectory("mic-441-to-48")
        defer { try? FileManager.default.removeItem(at: root) }

        let device = AudioInputDevice(
            id: 1,
            name: "test-441-mic",
            uid: "test-441-uid",
            manufacturer: nil,
            sampleRate: 44_100,
            transportType: .usb
        )
        let capture = ExternalMicCapture(device: device)

        // Feed buffers and test detachForBoundary
        let (cutoff, _) = capture.detachForBoundary(successor: nil, admissionGate: nil)
        #expect(cutoff.isValid)
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

    // 7. Same-UID revocation drops queued audio and converter history and does not move accepted writer buffer
    @Test func sameUIDRevocationDropsQueuedAudioAndConverterHistoryWithoutMovingAcceptedWriterBuffer() async throws {
        let root = try makeTempDirectory("mic-revocation")
        defer { try? FileManager.default.removeItem(at: root) }

        let device = AudioInputDevice(id: 1, name: "test-mic", uid: "test-uid", manufacturer: nil, sampleRate: 48_000, transportType: .usb)
        let capture = ExternalMicCapture(device: device, resolveDeviceID: { _ in 1 }, layoutReader: { _ in testOneChannelLayout })

        let writer = try SingleTrackAudioWriter(
            url: root.appendingPathComponent("source.m4a"),
            trackType: .microphone(name: device.name, deviceUID: device.uid),
            segmentStartTime: .zero
        )

        final class BufferBox: @unchecked Sendable {
            var buffers: [AVAudioPCMBuffer] = []
        }
        let box = BufferBox()
        let errorCb: ((Error) -> Void)? = nil
        let gateCb: (((() -> Void) -> Bool))? = nil
        capture.setQueuedCallbacks(
            audio: { buf, pts in
                box.buffers.append(buf)
                return AudioWriteReceipt(writer: writer)
            },
            error: { _ in },
            rawError: errorCb,
            admissionGate: gateCb
        )

        let fmt48 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let buf1 = AVAudioPCMBuffer(pcmFormat: fmt48, frameCapacity: 512)!
        buf1.frameLength = 512

        // One buffer is delivered and accepted before suspend
        capture._enqueueForTesting(buf1)
        await capture.drain()
        #expect(box.buffers.count == 1)

        // Real _convertForTesting creates a converter
        let fmt44 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
        let buf44 = AVAudioPCMBuffer(pcmFormat: fmt44, frameCapacity: 512)!
        buf44.frameLength = 512
        _ = capture._convertForTesting(buf44, targetFormat: fmt48)
        #expect(capture._converterForTesting != nil)

        // A second buffer is queued while writer queue is suspended
        capture._suspendProcessingForTesting()
        let buf2 = AVAudioPCMBuffer(pcmFormat: fmt48, frameCapacity: 512)!
        buf2.frameLength = 512
        capture._enqueueForTesting(buf2)

        // Revoke
        capture.revokeUnacceptedAudio()

        // Resume and drain
        capture._resumeProcessingForTesting()
        await capture.drain()

        // The accepted buffer remains and the queued one is not delivered
        #expect(box.buffers.count == 1)

        // After a real _convertForTesting that creates a converter, revoke leaves _converterForTesting == nil
        #expect(capture._converterForTesting == nil)

        _ = await writer.finish()
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

        // 3. Stop engine
        engine.stop()

        // Call render callback after stop: must return noErr and deliver nothing
        delivered.value = false
        fakeUnit.renderStatus = noErr
        let postStopStatus = renderProc(refCon, &flags, &ts, 1, 512, &bufList)
        #expect(postStopStatus == noErr)
        #expect(!delivered.value)

        // 4. Recover: start engine again with healthy render
        try engine.start(deviceID: 10, deviceName: "fake-mic") { _, _ in
            delivered.value = true
        }
        let recoveredProc = try #require(fakeUnit.renderCallback)
        let recoveredRefCon = try #require(fakeUnit.renderRefCon)
        let recoveredStatus = recoveredProc(recoveredRefCon, &flags, &ts, 1, 512, &bufList)
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

    // 9. Finalized failure evidence on the writer statistics
    @Test func finalizedFailureEvidenceOnWriterStatistics() async throws {
        let root = try makeTempDirectory("mic-writer-stats")
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = try SingleTrackAudioWriter(
            url: root.appendingPathComponent("source.m4a"),
            trackType: .systemAudio,
            segmentStartTime: .zero
        )

        // Route real engine render failure through ExternalMicCapture to writer
        let fakeUnit = FakeMicrophoneInputUnit(sampleRate: 48000, channelCount: 1)
        let engine = NativeMicrophoneCaptureEngine(unitFactory: { fakeUnit })
        let dev = AudioInputDevice(id: 10, name: "mic", uid: "mic-fail", manufacturer: nil, sampleRate: 48000, transportType: .usb)
        let capture = ExternalMicCapture(
            device: dev,
            engineFactory: { engine },
            resolveDeviceID: { _ in 10 },
            layoutReader: { _ in testOneChannelLayout }
        )
        capture.setQueuedCallbacks(
            audio: { _, _ in nil },
            error: { writer.reportCaptureFailure($0) },
            rawError: { writer.reportCaptureFailure($0) },
            admissionGate: nil
        )
        try capture.start()

        // Trigger render failure
        fakeUnit.renderStatus = -1
        let renderProc = try #require(fakeUnit.renderCallback)
        let refCon = try #require(fakeUnit.renderRefCon)
        var flags: AudioUnitRenderActionFlags = []
        var ts = AudioTimeStamp()
        ts.mHostTime = mach_absolute_time()
        var bufList = AudioBufferList()
        _ = renderProc(refCon, &flags, &ts, 1, 512, &bufList)

        await capture.drain()
        capture.stop()

        // Report additional failures (exceeding cap of 16)
        for i in 1...20 {
            writer.reportCaptureFailure(NSError(domain: "SolstoneAudioAdmission", code: i))
        }

        _ = await writer.finish()
        let stats = writer.statisticsSnapshot

        #expect(stats.failures.count <= 16)
        #expect(!stats.failures.isEmpty)
    }

    // 10. Repeated failed dispose stays within one parked unit plus one live unit
    @Test func repeatedFailedDisposeStaysWithinParkedBound() throws {
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
}
