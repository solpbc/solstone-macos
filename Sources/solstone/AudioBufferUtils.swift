// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFAudio
import CoreMedia

/// Utilities for creating silent copies of audio buffers
public enum AudioBufferUtils {

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
