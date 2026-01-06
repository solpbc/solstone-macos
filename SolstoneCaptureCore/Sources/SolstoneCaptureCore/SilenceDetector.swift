// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Accelerate
import Foundation

/// Configuration for silence detection
public struct SilenceDetectionConfig: Sendable {
    /// RMS threshold below which audio is considered silent (linear scale)
    /// Default 0.01 is approximately -40 dB
    public let rmsThreshold: Float

    /// Minimum cumulative duration of non-silent audio to consider mic "active"
    public let minActiveDuration: TimeInterval

    public init(rmsThreshold: Float = 0.01, minActiveDuration: TimeInterval = 0.5) {
        self.rmsThreshold = rmsThreshold
        self.minActiveDuration = minActiveDuration
    }
}

/// Tracks audio activity for a single microphone
public final class SilenceDetector: @unchecked Sendable {
    private let config: SilenceDetectionConfig
    private let lock = NSLock()

    private var totalActiveDuration: TimeInterval = 0

    public init(config: SilenceDetectionConfig = SilenceDetectionConfig()) {
        self.config = config
    }

    /// Process a buffer of Float32 audio samples
    /// - Parameters:
    ///   - samples: Pointer to Float32 samples
    ///   - count: Number of samples
    ///   - bufferDuration: Duration of this buffer in seconds
    public func processBuffer(_ samples: UnsafePointer<Float>, count: Int, bufferDuration: TimeInterval) {
        guard count > 0 else { return }

        // Calculate RMS using vDSP
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))

        lock.lock()
        if rms > config.rmsThreshold {
            totalActiveDuration += bufferDuration
        }
        lock.unlock()
    }

    /// Returns true if this mic had meaningful audio during the segment
    public var hadMeaningfulAudio: Bool {
        lock.lock()
        defer { lock.unlock() }
        return totalActiveDuration >= config.minActiveDuration
    }

    /// Returns the total duration of active audio
    public var activeDuration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return totalActiveDuration
    }

    /// Reset the detector for a new segment
    public func reset() {
        lock.lock()
        totalActiveDuration = 0
        lock.unlock()
    }
}
