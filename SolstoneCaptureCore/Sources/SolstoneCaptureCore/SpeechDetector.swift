// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation
import Speech

/// Result of speech detection analysis
public enum SpeechDetectionResult: Sendable {
    case speechDetected
    case noSpeech
    case unavailable(reason: String)
}

/// Detects speech presence in audio files using on-device recognition
public final class SpeechDetector: Sendable {
    /// Shared instance
    public static let shared = SpeechDetector()

    private init() {}

    /// Current authorization status
    public var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    /// Whether speech detection is available and authorized
    public var isAvailable: Bool {
        guard authorizationStatus == .authorized else { return false }
        guard let recognizer = SFSpeechRecognizer() else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    /// Request authorization (call once at app startup)
    public static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        // Use withUnsafeContinuation because the callback may come on any thread
        // and the continuation is safe to resume from any context
        await withUnsafeContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Analyze an audio file for speech presence
    /// - Parameters:
    ///   - url: URL to the M4A audio file
    ///   - timeout: Maximum time to wait for recognition (default 10s)
    /// - Returns: Detection result
    public func detectSpeech(in url: URL, timeout: TimeInterval = 10.0) async -> SpeechDetectionResult {
        // Check authorization
        guard authorizationStatus == .authorized else {
            return .unavailable(reason: "Speech recognition not authorized")
        }

        // Create recognizer with default locale
        guard let recognizer = SFSpeechRecognizer() else {
            return .unavailable(reason: "Speech recognizer not available")
        }

        // Require on-device only (privacy requirement)
        guard recognizer.supportsOnDeviceRecognition else {
            return .unavailable(reason: "On-device recognition not supported")
        }

        guard recognizer.isAvailable else {
            return .unavailable(reason: "Speech recognizer not currently available")
        }

        // Create recognition request
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        // Perform recognition with timeout using a helper actor
        return await RecognitionHelper.performRecognition(
            recognizer: recognizer,
            request: request,
            timeout: timeout
        )
    }
}

/// Thread-safe state for speech recognition
private final class RecognitionState: @unchecked Sendable {
    private let lock = NSLock()
    private var _hasResumed = false
    private var _task: SFSpeechRecognitionTask?

    var hasResumed: Bool {
        get { lock.withLock { _hasResumed } }
        set { lock.withLock { _hasResumed = newValue } }
    }

    var task: SFSpeechRecognitionTask? {
        get { lock.withLock { _task } }
        set { lock.withLock { _task = newValue } }
    }

    func tryResume() -> Bool {
        lock.withLock {
            if _hasResumed { return false }
            _hasResumed = true
            return true
        }
    }
}

/// Helper for performing speech recognition with timeout
private enum RecognitionHelper {
    static func performRecognition(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechURLRecognitionRequest,
        timeout: TimeInterval
    ) async -> SpeechDetectionResult {
        let state = RecognitionState()

        return await withCheckedContinuation { continuation in
            // Start recognition
            let recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                guard state.tryResume() else { return }

                if let error = error {
                    Log.debug("Speech recognition error: \(error)", verbose: true)
                    continuation.resume(returning: .noSpeech)
                    return
                }

                guard let result = result, result.isFinal else {
                    // Not final yet, but we already marked as resumed - this shouldn't happen
                    // but handle it gracefully
                    return
                }

                let text = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    Log.debug("Speech detected: \"\(text.prefix(50))...\"", verbose: true)
                    continuation.resume(returning: .speechDetected)
                } else {
                    continuation.resume(returning: .noSpeech)
                }
            }

            state.task = recognitionTask

            // Set up timeout using DispatchQueue (avoids Sendable issues with Task)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard state.tryResume() else { return }
                state.task?.cancel()
                continuation.resume(returning: .unavailable(reason: "Recognition timed out"))
            }
        }
    }
}
