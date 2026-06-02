import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

private enum MediaFixtureError: Error {
    case writerStartFailed(Error?)
    case writerAppendFailed
    case writerFinishFailed(Error?)
    case formatDescriptionFailed(OSStatus)
    case blockBufferFailed(OSStatus)
    case sampleBufferFailed(OSStatus)
    case pixelBufferFailed(CVReturn)
}

enum IncompleteSegmentAudio {
    case validM4A
    case corrupt
    case none
}

@discardableResult
func makeIncompleteSegment(
    root: URL,
    date: String? = nil,
    time: String = "120000",
    audio: IncompleteSegmentAudio = .validM4A,
    createdSecondsAgo: TimeInterval = 0
) async throws -> (dir: URL, audio: URL?) {
    let fm = FileManager.default
    let parent = date.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
    try fm.createDirectory(at: parent, withIntermediateDirectories: true)

    let dir = parent.appendingPathComponent("\(time).incomplete", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)

    try await makeTinyValidMP4(
        at: dir.appendingPathComponent("\(time)_display_42_screen.mp4"),
        seconds: 1.2
    )

    let audioURL: URL?
    switch audio {
    case .validM4A:
        let a = dir.appendingPathComponent("\(time)_audio_system.m4a")
        try await makeTinyValidM4A(at: a)
        audioURL = a
    case .corrupt:
        let a = dir.appendingPathComponent("\(time)_audio_system.m4a")
        try corruptM4A(at: a)
        audioURL = a
    case .none:
        audioURL = nil
    }

    if createdSecondsAgo > 0 {
        try fm.setAttributes(
            [.creationDate: Date(timeIntervalSinceNow: -createdSecondsAgo)],
            ofItemAtPath: dir.path
        )
    }

    return (dir, audioURL)
}

func makeTinyValidM4A(at url: URL, seconds: Double = 0.2) async throws {
    try? FileManager.default.removeItem(at: url)

    let writer = try AVAssetWriter(url: url, fileType: .m4a)
    let input = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
    )
    input.expectsMediaDataInRealTime = false

    guard writer.canAdd(input) else { throw MediaFixtureError.writerAppendFailed }
    writer.add(input)
    guard writer.startWriting() else { throw MediaFixtureError.writerStartFailed(writer.error) }
    writer.startSession(atSourceTime: .zero)

    while !input.isReadyForMoreMediaData {
        try await Task.sleep(for: .milliseconds(1))
    }

    let sampleBuffer = try makeSilentAudioSampleBuffer(seconds: seconds)
    guard input.append(sampleBuffer) else { throw MediaFixtureError.writerAppendFailed }
    input.markAsFinished()
    await writer.finishWriting()

    guard writer.status == .completed else {
        throw MediaFixtureError.writerFinishFailed(writer.error)
    }
}

func corruptM4A(at url: URL) throws {
    let bytes = Data([
        0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70,
        0x4D, 0x34, 0x41, 0x20, 0x00, 0x00, 0x00, 0x00,
        0x4D, 0x34, 0x41, 0x20, 0x69, 0x73, 0x6F, 0x6D,
        0x00, 0x00, 0x00, 0x08, 0x6D, 0x6F, 0x6F, 0x76,
    ])
    try bytes.write(to: url)
}

func makeTinyValidMP4(at url: URL, seconds: Double = 0.2) async throws {
    try? FileManager.default.removeItem(at: url)

    let writer = try AVAssetWriter(url: url, fileType: .mp4)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 16,
            AVVideoHeightKey: 16,
        ]
    )
    input.expectsMediaDataInRealTime = false

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 16,
            kCVPixelBufferHeightKey as String: 16,
        ]
    )

    guard writer.canAdd(input) else { throw MediaFixtureError.writerAppendFailed }
    writer.add(input)
    guard writer.startWriting() else { throw MediaFixtureError.writerStartFailed(writer.error) }
    writer.startSession(atSourceTime: .zero)

    let firstFrame = try makeBlackPixelBuffer()
    let secondFrame = try makeBlackPixelBuffer()
    while !input.isReadyForMoreMediaData {
        try await Task.sleep(for: .milliseconds(1))
    }
    guard adaptor.append(firstFrame, withPresentationTime: .zero) else {
        throw MediaFixtureError.writerAppendFailed
    }
    guard adaptor.append(
        secondFrame,
        withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600)
    ) else {
        throw MediaFixtureError.writerAppendFailed
    }

    input.markAsFinished()
    await writer.finishWriting()

    guard writer.status == .completed else {
        throw MediaFixtureError.writerFinishFailed(writer.error)
    }
}

private func makeSilentAudioSampleBuffer(seconds: Double) throws -> CMSampleBuffer {
    let sampleRate: Double = 48_000
    let sampleCount = max(1, Int(sampleRate * seconds))
    let byteCount = sampleCount * MemoryLayout<Float>.size

    var asbd = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
        mFramesPerPacket: 1,
        mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
        mChannelsPerFrame: 1,
        mBitsPerChannel: 32,
        mReserved: 0
    )

    var formatDescription: CMAudioFormatDescription?
    var status = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &asbd,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDescription
    )
    guard status == noErr, let formatDescription else {
        throw MediaFixtureError.formatDescriptionFailed(status)
    }

    var blockBuffer: CMBlockBuffer?
    status = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: byteCount,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: byteCount,
        flags: 0,
        blockBufferOut: &blockBuffer
    )
    guard status == noErr, let blockBuffer else {
        throw MediaFixtureError.blockBufferFailed(status)
    }

    let silence = Data(count: byteCount)
    status = silence.withUnsafeBytes { bytes in
        CMBlockBufferReplaceDataBytes(
            with: bytes.baseAddress!,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        )
    }
    guard status == noErr else {
        throw MediaFixtureError.blockBufferFailed(status)
    }

    var sampleBuffer: CMSampleBuffer?
    status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        formatDescription: formatDescription,
        sampleCount: sampleCount,
        presentationTimeStamp: .zero,
        packetDescriptions: nil,
        sampleBufferOut: &sampleBuffer
    )
    guard status == noErr, let sampleBuffer else {
        throw MediaFixtureError.sampleBufferFailed(status)
    }

    return sampleBuffer
}

private func makeBlackPixelBuffer() throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        16,
        16,
        kCVPixelFormatType_32BGRA,
        nil,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw MediaFixtureError.pixelBufferFailed(status)
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
        memset(baseAddress, 0, CVPixelBufferGetDataSize(pixelBuffer))
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    return pixelBuffer
}
