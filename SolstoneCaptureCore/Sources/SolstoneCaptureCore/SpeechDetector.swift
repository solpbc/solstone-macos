// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SoundAnalysis

/// Result of speech detection analysis
public enum SpeechDetectionResult: Sendable {
    case speechDetected
    case noSpeech
    case unavailable(reason: String)
}

/// Detects speech presence in audio files using SoundAnalysis
public final class SpeechDetector: Sendable {
    /// Shared instance
    public static let shared = SpeechDetector()

    private init() {}

    /// Analyze an audio file for speech presence
    /// - Parameters:
    ///   - url: URL to the audio file
    ///   - confidenceThreshold: Minimum confidence to consider speech detected (default 0.5)
    /// - Returns: Detection result
    public func detectSpeech(in url: URL, confidenceThreshold: Double = 0.5) async -> SpeechDetectionResult {
        do {
            let analyzer = try SNAudioFileAnalyzer(url: url)
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)

            let observer = SpeechObserver(threshold: confidenceThreshold)
            try analyzer.add(request, withObserver: observer)

            // analyze() processes the entire file at high speed
            await analyzer.analyze()

            if observer.speechDetected {
                return .speechDetected
            } else {
                return .noSpeech
            }
        } catch {
            Log.debug("SoundAnalysis failed: \(error.localizedDescription), failing open", verbose: true)
            return .unavailable(reason: error.localizedDescription)
        }
    }
}

/// Observer for speech classification results
private class SpeechObserver: NSObject, SNResultsObserving {
    let threshold: Double
    private(set) var speechDetected = false

    init(threshold: Double) {
        self.threshold = threshold
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = result as? SNClassificationResult else { return }
        if classification.classifications.contains(where: {
            $0.identifier == "speech" && $0.confidence > threshold
        }) {
            speechDetected = true
        }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        Log.debug("SoundAnalysis request failed: \(error.localizedDescription)", verbose: true)
    }

    func requestDidComplete(_ request: SNRequest) {
        // Analysis complete
    }
}
