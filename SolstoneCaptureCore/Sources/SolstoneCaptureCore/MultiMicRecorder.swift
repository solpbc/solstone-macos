// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Configuration for multi-microphone recording
public struct MultiMicConfig: Sendable {
    /// Maximum number of microphones to capture simultaneously
    public let maxMicrophones: Int

    /// Silence detection configuration
    public let silenceConfig: SilenceDetectionConfig

    public init(
        maxMicrophones: Int = 4,
        silenceConfig: SilenceDetectionConfig = SilenceDetectionConfig()
    ) {
        self.maxMicrophones = maxMicrophones
        self.silenceConfig = silenceConfig
    }
}

/// Information about a microphone recording for a segment
public struct MicFileInfo: Sendable, Codable {
    /// Device name (e.g., "MacBook Pro Microphone")
    public let deviceName: String

    /// URL to the audio file
    public let url: URL

    /// Native sample rate of the device
    public let sampleRate: Double

    /// Seconds from segment start when this mic started recording
    public let startOffset: TimeInterval

    /// How long the mic recorded in this segment
    public let duration: TimeInterval

    public init(deviceName: String, url: URL, sampleRate: Double, startOffset: TimeInterval, duration: TimeInterval) {
        self.deviceName = deviceName
        self.url = url
        self.sampleRate = sampleRate
        self.startOffset = startOffset
        self.duration = duration
    }
}

/// Result of finishing a multi-mic recording session
public struct MultiMicResult: Sendable {
    /// Files from mics that had meaningful audio (with timing info)
    public let activeFiles: [MicFileInfo]

    /// Number of files discarded due to silence
    public let silentCount: Int

    /// Total duration of the segment
    public let segmentDuration: TimeInterval
}

/// Manages recording from multiple microphones simultaneously
public final class MultiMicRecorder: @unchecked Sendable {
    private let config: MultiMicConfig
    private let outputDirectory: URL
    private let filePrefix: String
    private let verbose: Bool

    private var micInputs: [MicrophoneInput] = []
    private let lock = NSLock()
    private var isRecording = false
    private var segmentStartTime: Date?

    /// Creates a new multi-mic recorder
    /// - Parameters:
    ///   - outputDirectory: Directory to write audio files
    ///   - filePrefix: Prefix for file names (typically HHMMSS)
    ///   - config: Configuration for recording
    ///   - verbose: Enable verbose logging
    public init(
        outputDirectory: URL,
        filePrefix: String,
        config: MultiMicConfig = MultiMicConfig(),
        verbose: Bool = false
    ) {
        self.outputDirectory = outputDirectory
        self.filePrefix = filePrefix
        self.config = config
        self.verbose = verbose
    }

    /// Start recording from all available microphones
    /// - Parameter excludingUIDs: Set of device UIDs to exclude from recording (e.g., disabled mics)
    /// - Returns: Number of microphones started
    @discardableResult
    public func start(excludingUIDs: Set<String> = []) throws -> Int {
        lock.lock()
        defer { lock.unlock() }

        guard !isRecording else { return micInputs.count }

        // Get available input devices, filtering out excluded UIDs
        let allDevices = MicrophoneMonitor.listInputDevices()
        let devices = allDevices.filter { !excludingUIDs.contains($0.uid) }
        let devicesToCapture = Array(devices.prefix(config.maxMicrophones))

        Log.debug("Starting multi-mic capture for \(devicesToCapture.count) device(s)", verbose: verbose)

        // Create and start a MicrophoneInput for each device
        for (index, device) in devicesToCapture.enumerated() {
            // Create safe filename from device name
            let safeDeviceName = device.name
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
                .replacingOccurrences(of: " ", with: "_")

            let filename = "\(filePrefix)_mic\(index + 1)_\(safeDeviceName).m4a"
            let outputURL = outputDirectory.appendingPathComponent(filename)

            let input = MicrophoneInput(
                device: device,
                deviceIndex: index,
                outputURL: outputURL,
                silenceConfig: config.silenceConfig,
                verbose: verbose
            )

            do {
                try input.start()
                micInputs.append(input)

                Log.debug("Started capture for: \(device.name) -> \(filename)", verbose: verbose)
            } catch {
                Log.warn("Failed to start capture for \(device.name): \(error)")
            }
        }

        isRecording = true
        segmentStartTime = Date()
        return micInputs.count
    }

    /// Stop all microphone recording and return results
    /// - Parameter deleteInactive: If true, delete files from mics that had no meaningful audio
    /// - Returns: Result containing active files and counts
    public func stop(deleteInactive: Bool = true) -> MultiMicResult {
        lock.lock()
        defer { lock.unlock() }

        let segmentDuration = segmentStartTime.map { Date().timeIntervalSince($0) } ?? 0

        guard isRecording else {
            return MultiMicResult(activeFiles: [], silentCount: 0, segmentDuration: segmentDuration)
        }

        // Stop all inputs
        for input in micInputs {
            input.stop()
        }

        // Separate into active and silent, collect timing info
        var activeFiles: [MicFileInfo] = []
        var silentCount = 0

        for input in micInputs {
            if input.hadMeaningfulAudio {
                // Calculate start offset relative to segment start
                let startOffset: TimeInterval
                if let micStart = input.startTime, let segStart = segmentStartTime {
                    startOffset = micStart.timeIntervalSince(segStart)
                } else {
                    startOffset = 0
                }

                let fileInfo = MicFileInfo(
                    deviceName: input.device.name,
                    url: input.fileURL,
                    sampleRate: input.nativeSampleRate,
                    startOffset: max(0, startOffset),
                    duration: input.recordingDuration
                )
                activeFiles.append(fileInfo)
                Log.debug("Active mic: \(input.device.name) (offset: \(String(format: "%.1f", startOffset))s, duration: \(String(format: "%.1f", input.recordingDuration))s)", verbose: verbose)
            } else {
                silentCount += 1
                Log.debug("Silent mic (discarding): \(input.device.name)", verbose: verbose)
                if deleteInactive {
                    try? FileManager.default.removeItem(at: input.fileURL)
                }
            }
        }

        micInputs.removeAll()
        isRecording = false
        segmentStartTime = nil

        return MultiMicResult(
            activeFiles: activeFiles,
            silentCount: silentCount,
            segmentDuration: segmentDuration
        )
    }

    /// Rotate all microphone recordings to new files (hot swap without stopping)
    /// - Parameters:
    ///   - newDirectory: New output directory for the next segment
    ///   - newFilePrefix: New file prefix for the next segment
    ///   - deleteInactive: If true, delete files from mics that had no meaningful audio
    ///   - renamedDirectory: The renamed directory of the previous segment (for correct file deletion)
    /// - Returns: Result containing active files from the PREVIOUS segment
    public func rotate(
        to newDirectory: URL,
        filePrefix newFilePrefix: String,
        deleteInactive: Bool = true,
        renamedDirectory: URL? = nil
    ) -> MultiMicResult {
        lock.lock()
        defer { lock.unlock() }

        let oldSegmentStart = segmentStartTime
        let segmentDuration = oldSegmentStart.map { Date().timeIntervalSince($0) } ?? 0

        guard isRecording else {
            return MultiMicResult(activeFiles: [], silentCount: 0, segmentDuration: segmentDuration)
        }

        var activeFiles: [MicFileInfo] = []
        var silentCount = 0

        // Rotate each mic input to new files
        for input in micInputs {
            // Create safe filename from device name
            let safeDeviceName = input.device.name
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
                .replacingOccurrences(of: " ", with: "_")

            let filename = "\(newFilePrefix)_mic\(input.deviceIndex + 1)_\(safeDeviceName).m4a"
            let newURL = newDirectory.appendingPathComponent(filename)

            do {
                // Get timing info before rotation (startTime is from old segment)
                let micStartTime = input.startTime

                let (oldURL, hadAudio, duration) = try input.rotate(to: newURL)

                if hadAudio {
                    // Calculate start offset relative to old segment start
                    let startOffset: TimeInterval
                    if let micStart = micStartTime, let segStart = oldSegmentStart {
                        startOffset = micStart.timeIntervalSince(segStart)
                    } else {
                        startOffset = 0
                    }

                    // Use renamed directory if provided (segment may have been renamed)
                    let fileURL: URL
                    if let renamedDir = renamedDirectory {
                        fileURL = renamedDir.appendingPathComponent(oldURL.lastPathComponent)
                    } else {
                        fileURL = oldURL
                    }

                    let fileInfo = MicFileInfo(
                        deviceName: input.device.name,
                        url: fileURL,
                        sampleRate: input.nativeSampleRate,
                        startOffset: max(0, startOffset),
                        duration: duration
                    )
                    activeFiles.append(fileInfo)
                    Log.debug("Active mic: \(input.device.name) (offset: \(String(format: "%.1f", startOffset))s, duration: \(String(format: "%.1f", duration))s)", verbose: verbose)
                } else {
                    silentCount += 1
                    if deleteInactive {
                        let fm = FileManager.default

                        // Check if file exists at original path (before any rename)
                        let oldExists = fm.fileExists(atPath: oldURL.path)

                        // Use renamed directory if provided (segment may have been renamed)
                        let deleteURL: URL
                        if let renamedDir = renamedDirectory {
                            deleteURL = renamedDir.appendingPathComponent(oldURL.lastPathComponent)
                            Log.info("Silent mic '\(input.device.name)':")
                            Log.info("  original path: \(oldURL.path) (exists: \(oldExists))")
                            Log.info("  renamed path:  \(deleteURL.path)")
                        } else {
                            deleteURL = oldURL
                            Log.info("Silent mic '\(input.device.name)': \(deleteURL.path) (exists: \(oldExists))")
                        }

                        if fm.fileExists(atPath: deleteURL.path) {
                            do {
                                try fm.removeItem(at: deleteURL)
                                Log.info("  -> Deleted successfully")
                            } catch {
                                Log.warn("  -> Delete FAILED: \(error)")
                            }
                        } else if oldExists {
                            // File exists at old path but not renamed path - directory wasn't renamed?
                            Log.warn("  -> File exists at ORIGINAL path but not renamed path!")
                            do {
                                try fm.removeItem(at: oldURL)
                                Log.info("  -> Deleted from original path instead")
                            } catch {
                                Log.warn("  -> Delete from original FAILED: \(error)")
                            }
                        } else {
                            Log.warn("  -> File does NOT exist at either path!")
                        }
                    } else {
                        Log.debug("Silent mic (not deleting, deleteInactive=false): \(input.device.name)", verbose: verbose)
                    }
                }
            } catch {
                Log.warn("Failed to rotate mic \(input.device.name): \(error)")
            }
        }

        // Reset segment start time for new segment
        segmentStartTime = Date()

        return MultiMicResult(
            activeFiles: activeFiles,
            silentCount: silentCount,
            segmentDuration: segmentDuration
        )
    }

    /// Whether recording is currently active
    public var recording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRecording
    }

    /// Number of microphones currently being recorded
    public var microphoneCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return micInputs.count
    }
}
