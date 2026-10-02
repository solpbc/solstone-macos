// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import CoreMedia
import Foundation
import os

/// Input for the audio remixer
public struct AudioRemixerInput: Sendable {
    /// URL to the source M4A file
    public let url: URL
    /// Timing information for alignment
    public let timingInfo: AudioTrackTimingInfo

    public init(url: URL, timingInfo: AudioTrackTimingInfo) {
        self.url = url
        self.timingInfo = timingInfo
    }
}

/// Content-free disposition for each source, persisted before raw cleanup.
public struct AudioSourceRemixResult: Codable, Sendable {
    public let sourceID: String
    public var state: String
    public var stage: String?
    public var errorDomain: String?
    public var errorCode: Int?
    public var framesCopied: Int = 0
    public var musicAnalysis: String?

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id", state, stage
        case errorDomain = "error_domain", errorCode = "error_code"
        case framesCopied = "frames_copied", musicAnalysis = "music_analysis"
    }
    static func failure(sourceID: String, stage: String, error: Error?, state: String = "unreadable") -> Self {
        let native = error as NSError?
        return Self(sourceID: sourceID, state: state, stage: stage, errorDomain: native?.domain, errorCode: native?.code)
    }
}

public struct AudioRemixerResult: Sendable {
    public let tracksWritten: Int
    public let tracksSkipped: Int
    /// Only sources fully copied to a completed output qualify for cleanup.
    public let sourceFiles: [URL]
    public let sources: [AudioSourceRemixResult]
    public init(tracksWritten: Int, tracksSkipped: Int, sourceFiles: [URL], sources: [AudioSourceRemixResult] = []) {
        self.tracksWritten = tracksWritten
        self.tracksSkipped = tracksSkipped
        self.sourceFiles = sourceFiles
        self.sources = sources
    }
}

/// Combines readable sources; classification never authorizes file disposal.
public final class AudioRemixer: Sendable {
    private let verbose: Bool
    private static nonisolated(unsafe) let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
    ]
    public init(verbose: Bool = false) { self.verbose = verbose }

    public func remix(inputs: [AudioRemixerInput], to outputURL: URL,
                      silenceMusic: Bool = true) async throws -> AudioRemixerResult {
        guard !inputs.isEmpty else { throw AudioRemixerError.noInputs }
        let tempURL = outputURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let writer = try AVAssetWriter(url: tempURL, fileType: .m4a)
        var outcomes = inputs.map { AudioSourceRemixResult(sourceID: $0.timingInfo.trackType.sourceID, state: "pending") }
        var pairs: [(index: Int, reader: AVAssetReader, output: AVAssetReaderTrackOutput,
                     input: AVAssetWriterInput, offset: CMTime, silence: [CMTimeRange])] = []

        for (index, source) in inputs.enumerated() {
            let asset = AVURLAsset(url: source.url)
            let reader: AVAssetReader
            let output: AVAssetReaderTrackOutput
            do {
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                    outcomes[index] = .failure(sourceID: source.timingInfo.trackType.sourceID, stage: "reader", error: nil)
                    continue
                }
                reader = try AVAssetReader(asset: asset)
                output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                ])
                guard reader.canAdd(output) else {
                    outcomes[index] = .failure(sourceID: source.timingInfo.trackType.sourceID, stage: "reader", error: reader.error)
                    continue
                }
                reader.add(output)
            } catch {
                outcomes[index] = .failure(sourceID: source.timingInfo.trackType.sourceID, stage: "reader", error: error)
                continue
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                outcomes[index] = .failure(sourceID: source.timingInfo.trackType.sourceID, stage: "writer", error: writer.error, state: "partial")
                continue
            }
            writer.add(input)
            var ranges: [CMTimeRange] = []
            if silenceMusic, case .systemAudio = source.timingInfo.trackType {
                let analysis = await SystemAudioAnalyzer.shared.analyze(url: source.url)
                ranges = analysis.silenceRanges
                outcomes[index].musicAnalysis = analysis.status
            }
            pairs.append((index, reader, output, input, source.timingInfo.startOffset, ranges))
        }
        defer { for pair in pairs { pair.reader.cancelReading() } }
        guard !pairs.isEmpty else {
            if outcomes.allSatisfy({ $0.state == "unreadable" }) {
                throw AudioRemixerError.unreadableSources(sourceIDs: outcomes.map(\.sourceID))
            }
            throw AudioRemixerError.writeFailed(writer.error)
        }
        guard writer.startWriting() else { throw AudioRemixerError.failedToStartWriter(writer.error) }
        writer.startSession(atSourceTime: .zero)
        var finished = Set<Int>()
        for pair in pairs where !pair.reader.startReading() {
            outcomes[pair.index] = .failure(sourceID: outcomes[pair.index].sourceID, stage: "reader", error: pair.reader.error)
            pair.input.markAsFinished()
            finished.insert(pair.index)
        }
        var pending: [Int: CMSampleBuffer] = [:]
        while finished.count < pairs.count {
            try Task.checkCancellation()
            guard writer.status == .writing else { throw AudioRemixerError.writeFailed(writer.error) }
            for pair in pairs where !finished.contains(pair.index) {
                guard let sample = pending[pair.index] ?? pair.output.copyNextSampleBuffer() else {
                    if pair.reader.status == .completed {
                        if outcomes[pair.index].state == "pending" { outcomes[pair.index].state = "complete" }
                    } else {
                        let copied = outcomes[pair.index].framesCopied
                        outcomes[pair.index] = .failure(sourceID: outcomes[pair.index].sourceID, stage: "reader", error: pair.reader.error,
                                                        state: copied > 0 ? "partial" : "unreadable")
                        outcomes[pair.index].framesCopied = copied
                    }
                    pair.input.markAsFinished()
                    finished.insert(pair.index)
                    continue
                }
                guard pair.input.isReadyForMoreMediaData else { pending[pair.index] = sample; continue }
                var transformed = sample
                if !pair.silence.isEmpty {
                    guard let silenced = AudioBufferUtils.silencedCopy(of: sample, ranges: pair.silence) else {
                        throw AudioRemixerError.writeFailed(nil)
                    }
                    transformed = silenced
                }
                guard let retimed = retimeBuffer(transformed, offset: pair.offset) else {
                    throw AudioRemixerError.writeFailed(nil)
                }
                guard pair.input.append(retimed) else { throw AudioRemixerError.writeFailed(writer.error) }
                outcomes[pair.index].framesCopied += CMSampleBufferGetNumSamples(sample)
                pending.removeValue(forKey: pair.index)
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        if outcomes.allSatisfy({ $0.state == "unreadable" }) {
            writer.cancelWriting()
            throw AudioRemixerError.unreadableSources(sourceIDs: outcomes.map(\.sourceID))
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw AudioRemixerError.writeFailed(writer.error) }
        let fm = FileManager.default
        if fm.fileExists(atPath: outputURL.path) { try fm.removeItem(at: outputURL) }
        try fm.moveItem(at: tempURL, to: outputURL)
        let complete = inputs.enumerated().compactMap { outcomes[$0.offset].state == "complete" ? $0.element.url : nil }
        let written = outcomes.filter { $0.framesCopied > 0 }.count
        Logger.audio.notice("Remixed \(written, privacy: .public) audio sources; \(inputs.count - complete.count, privacy: .public) incomplete")
        return AudioRemixerResult(tracksWritten: written, tracksSkipped: inputs.count - written, sourceFiles: complete, sources: outcomes)
    }

    private func retimeBuffer(_ sampleBuffer: CMSampleBuffer, offset: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing) == noErr else { return nil }
        timing.presentationTimeStamp = CMTimeAdd(timing.presentationTimeStamp, offset)
        if timing.decodeTimeStamp.isNumeric { timing.decodeTimeStamp = CMTimeAdd(timing.decodeTimeStamp, offset) }
        var result: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &result)
        return status == noErr ? result : nil
    }
}

/// Errors for AudioRemixer
public enum AudioRemixerError: Error, LocalizedError {
    case noInputs
    case unreadableSources(sourceIDs: [String])
    case failedToStartWriter(Error?)
    case writeFailed(Error?)

    public var errorDescription: String? {
        switch self {
        case .noInputs:
            return "No input files provided"
        case let .unreadableSources(sourceIDs):
            return "\(sourceIDs.count) audio source(s) unreadable: \(sourceIDs.joined(separator: ", "))"
        case let .failedToStartWriter(error):
            return "Failed to start writer: \(error?.localizedDescription ?? "unknown error")"
        case let .writeFailed(error):
            return "Write failed: \(error?.localizedDescription ?? "unknown error")"
        }
    }
}
