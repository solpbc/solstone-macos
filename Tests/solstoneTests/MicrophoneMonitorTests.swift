// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreAudio
import Testing
@testable import solstone

@Suite("MicrophoneMonitor input configuration")
struct MicrophoneMonitorTests {
    private let header = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
    private let stride = MemoryLayout<AudioBuffer>.stride

    /// Extra storage makes an unsafe fixed-allocation mutation observable without
    /// allowing the fake HAL write to corrupt the ordinary test process.
    private func qualify(channels: [UInt32], queriedBuffers: Int? = nil,
                         returnedBytes: Int? = nil, declaredCount: UInt32? = nil) -> Bool {
        var allocatedCapacity = 0
        var diagnostics: [String] = []
        let queried = header + (queriedBuffers ?? channels.count) * stride
        let result = MicrophoneMonitor.hasInputChannels(
            deviceID: 42,
            querySize: { size in size = UInt32(queried); return noErr },
            readData: { size, storage in
                #expect(Int(size) == allocatedCapacity)
                storage.storeBytes(of: declaredCount ?? UInt32(channels.count), as: UInt32.self)
                for (index, count) in channels.enumerated() {
                    storage.advanced(by: header + index * stride).storeBytes(
                        of: AudioBuffer(mNumberChannels: count, mDataByteSize: 0, mData: nil), as: AudioBuffer.self)
                }
                size = UInt32(returnedBytes ?? (header + channels.count * stride))
                return noErr
            },
            allocate: { capacity, alignment in
                allocatedCapacity = capacity
                #expect(capacity >= queried)
                let storage = UnsafeMutableRawPointer.allocate(byteCount: max(capacity, queried) + 64, alignment: alignment)
                storage.initializeMemory(as: UInt8.self, repeating: 0xA5, count: max(capacity, queried) + 64)
                return storage
            },
            release: { storage in
                for offset in allocatedCapacity..<(allocatedCapacity + 64) {
                    #expect(storage.load(fromByteOffset: offset, as: UInt8.self) == 0xA5)
                }
                storage.deallocate()
            },
            diagnostic: { stage, _ in diagnostics.append(stage) }
        )
        let completeBytes = header + Int(declaredCount ?? UInt32(channels.count)) * stride
        let malformed = (returnedBytes ?? completeBytes) < completeBytes
        #expect(diagnostics == (malformed ? ["layout"] : []))
        return result
    }

    @Test func variableLayoutAndLaterBufferChannels() {
        #expect(qualify(channels: [0, 2]))
        #expect(!qualify(channels: [0, 0]))
        #expect(!qualify(channels: []))
    }

    @Test func returnedExtentRatherThanAllocatedExtent() {
        // HAL shrank to a complete one-buffer layout. The second positive buffer
        // is outside returned bytes and must never qualify the zero-channel twin.
        #expect(!qualify(channels: [0, 2], queriedBuffers: 2,
                        returnedBytes: header + stride, declaredCount: 1))
        #expect(qualify(channels: [1, 2], queriedBuffers: 2,
                       returnedBytes: header + stride, declaredCount: 1))
        #expect(!qualify(channels: [2, 0], returnedBytes: header + stride, declaredCount: 2))
        #expect(!qualify(channels: [2], returnedBytes: header, declaredCount: 0))
        var stages: [String] = []
        for returned in [header - 1, header + 2 * stride] {
            #expect(!MicrophoneMonitor.hasInputChannels(deviceID: 42,
                querySize: { size in size = UInt32(header + stride); return noErr },
                readData: { size, _ in size = UInt32(returned); return noErr },
                diagnostic: { stage, _ in stages.append(stage) }))
        }
        #expect(stages == ["layout", "layout"])
    }

    @Test func boundedSizeChangesAndOrdinaryErrors() {
        var queries = 0
        var reads = 0
        var reports: [String] = []
        #expect(!MicrophoneMonitor.hasInputChannels(deviceID: 42,
            querySize: { size in queries += 1; size = UInt32(header + stride); return noErr },
            readData: { _, _ in reads += 1; return kAudioHardwareBadPropertySizeError },
            diagnostic: { stage, _ in reports.append(stage) }))
        #expect(queries == 3 && reads == 3)
        #expect(reports == ["size_changed"])

        reads = 0; reports = []
        #expect(!MicrophoneMonitor.hasInputChannels(deviceID: 42,
            querySize: { size in size = UInt32(header + stride); return noErr },
            readData: { _, _ in reads += 1; return kAudioHardwareBadObjectError },
            diagnostic: { stage, _ in reports.append(stage) }))
        #expect(reads == 1 && reports == ["read"])
        #expect(!MicrophoneMonitor.hasInputChannels(deviceID: 42,
            querySize: { _ in kAudioHardwareBadObjectError },
            diagnostic: { stage, _ in reports.append(stage) }))
        #expect(reports == ["read", "size"])
    }

    @Test func growingLayoutSucceedsAfterRequery() {
        var reads = 0
        var queries = 0
        #expect(MicrophoneMonitor.hasInputChannels(deviceID: 42,
            querySize: { size in
                queries += 1; size = UInt32(header + queries * stride); return noErr
            },
            readData: { size, storage in
                reads += 1
                if reads == 1 { size = UInt32(header + 2 * stride); return kAudioHardwareBadPropertySizeError }
                storage.storeBytes(of: UInt32(2), as: UInt32.self)
                storage.advanced(by: header).storeBytes(of: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil), as: AudioBuffer.self)
                storage.advanced(by: header + stride).storeBytes(of: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil), as: AudioBuffer.self)
                size = UInt32(header + 2 * stride)
                return noErr
            }))
        #expect(reads == 2 && queries == 2)
    }
}
