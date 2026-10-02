// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFAudio
import CoreMedia

/// Utilities for creating silent copies of audio buffers
public enum AudioBufferUtils {

    /// Zero only frames wholly inside confirmed music intervals. Boundary frames
    /// remain intact, including speech in the same decoded buffer.
    public static func silencedCopy(of sampleBuffer: CMSampleBuffer, ranges: [CMTimeRange]) -> CMSampleBuffer? {
        guard let original = CMSampleBufferGetDataBuffer(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate.isFinite, asbd.mSampleRate > 0 else { return nil }
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        let length = CMBlockBufferGetDataLength(original)
        guard bytesPerFrame > 0, length == count * bytesPerFrame else { return nil }
        let start = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard start.isFinite else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(original, atOffset: 0, dataLength: length, destination: &bytes) == noErr else { return nil }
        for range in ranges {
            let rangeStart = range.start.seconds
            let rangeEnd = CMTimeRangeGetEnd(range).seconds
            guard rangeStart.isFinite, rangeEnd.isFinite else { return nil }
            let lower = Int(max(0, min(Double(count), ceil((rangeStart - start) * asbd.mSampleRate))))
            let upper = Int(max(0, min(Double(count), floor((rangeEnd - start) * asbd.mSampleRate))))
            if upper > lower { bytes.replaceSubrange((lower * bytesPerFrame)..<(upper * bytesPerFrame), with: repeatElement(0, count: (upper - lower) * bytesPerFrame)) }
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: length,
            flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        guard CMBlockBufferReplaceDataBytes(with: bytes, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) == noErr else { return nil }
        var result: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: count, presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            packetDescriptions: nil, sampleBufferOut: &result) == noErr else { return nil }
        return result
    }

    /// Create a silent copy of a CMSampleBuffer, preserving timing and format
    public static func silencedCopy(of sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return nil }

        // Get timing info from original buffer
        var timingInfo = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timingInfo)

        // Get audio format details
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        let bytesPerSample = Int(asbd?.mBytesPerFrame ?? 4)
        let dataSize = numSamples * bytesPerSample

        // Allocate zeroed memory that CMBlockBuffer will own
        guard let silentMemory = calloc(1, dataSize) else { return nil }

        // Create block buffer that owns the memory (kCFAllocatorMalloc will call free())
        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: silentMemory,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorMalloc,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let block = blockBuffer else {
            free(silentMemory)
            return nil
        }

        var silentBuffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDesc,
            sampleCount: numSamples,
            presentationTimeStamp: timingInfo.presentationTimeStamp,
            packetDescriptions: nil,
            sampleBufferOut: &silentBuffer
        )

        return silentBuffer
    }

    /// Create a silent copy of an AVAudioPCMBuffer, preserving format and length
    public static func silencedCopy(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let silentBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        silentBuffer.frameLength = buffer.frameLength

        // Zero-fill all channels
        if let floatData = silentBuffer.floatChannelData {
            let channelCount = Int(buffer.format.channelCount)
            let frameCount = Int(buffer.frameLength)
            for channel in 0..<channelCount {
                memset(floatData[channel], 0, frameCount * MemoryLayout<Float>.size)
            }
        }

        return silentBuffer
    }
}
