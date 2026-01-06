// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation

/// Writes audio from a single microphone to an M4A file
/// Uses AVAudioFile for simpler integration with AVAudioEngine
public final class MicAudioWriter: @unchecked Sendable {
    private var audioFile: AVAudioFile?
    private let outputURL: URL
    private let lock = NSLock()
    private let verbose: Bool

    private var finished = false
    private var totalFramesWritten: AVAudioFrameCount = 0

    /// The sample rate of the output file
    public let sampleRate: Double

    /// Creates a new mic audio writer
    /// - Parameters:
    ///   - url: Output URL for the M4A file
    ///   - sampleRate: Sample rate for the output (typically 48000)
    ///   - verbose: Enable verbose logging
    public init(url: URL, sampleRate: Double = 48_000, verbose: Bool = false) throws {
        self.outputURL = url
        self.sampleRate = sampleRate
        self.verbose = verbose

        // Remove existing file if present
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        // Create output format: AAC mono
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]

        // Processing format: Float32 mono at the same sample rate
        guard
            let processingFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            )
        else {
            throw MicAudioWriterError.invalidFormat
        }

        self.audioFile = try AVAudioFile(
            forWriting: url,
            settings: outputSettings,
            commonFormat: processingFormat.commonFormat,
            interleaved: false
        )

        Log.debug("Created mic audio writer: \(url.lastPathComponent)", verbose: verbose)
    }

    /// Write audio samples from an AVAudioPCMBuffer
    /// - Parameter buffer: The audio buffer to write
    public func write(_ buffer: AVAudioPCMBuffer) throws {
        lock.lock()
        defer { lock.unlock() }

        guard !finished, let audioFile = audioFile else { return }

        try audioFile.write(from: buffer)
        totalFramesWritten += buffer.frameLength
    }

    /// Finish writing and close the file
    /// - Returns: Duration in seconds of audio written
    @discardableResult
    public func finish() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }

        guard !finished else {
            return Double(totalFramesWritten) / sampleRate
        }

        finished = true
        let duration = Double(totalFramesWritten) / sampleRate

        // AVAudioFile automatically closes when deallocated
        audioFile = nil

        Log.debug("Finished mic audio: \(outputURL.lastPathComponent) (\(String(format: "%.1f", duration))s)", verbose: verbose)

        return duration
    }

    /// The output file URL
    public var url: URL {
        outputURL
    }

    /// Whether this writer has been finished
    public var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    public enum MicAudioWriterError: Error, LocalizedError {
        case invalidFormat

        public var errorDescription: String? {
            switch self {
            case .invalidFormat:
                return "Failed to create audio format"
            }
        }
    }
}
