// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import CoreMedia
import Foundation
import os

func audioSourceFiles(in files: [URL], timePrefix: String) -> [URL] {
    files.filter { file in
        let name = file.lastPathComponent
        return name.hasPrefix("\(timePrefix)_audio_") && name.hasSuffix(".m4a")
    }
}

/// Single source of truth for classifying a segment directory's on-disk audio source files.
enum AudioSourceReadiness {
    case noSources                  // no per-source audio files present
    case ready([AudioRemixerInput]) // sources present and at least one is readable
    case unreadable                 // sources present but none yielded valid timing
}

/// Classify the per-source audio files in `files` into one readiness state.
/// Composes `audioSourceFiles` + `buildAudioInputs` so both reconstruction call sites share one decision.
func classifyAudioSources(in files: [URL], timePrefix: String, verbose: Bool) async -> AudioSourceReadiness {
    let sources = audioSourceFiles(in: files, timePrefix: timePrefix)
    guard !sources.isEmpty else { return .noSources }
    let inputs = await buildAudioInputs(from: sources, timePrefix: timePrefix, verbose: verbose)
    return inputs.isEmpty ? .unreadable : .ready(inputs)
}

func buildAudioInputs(from audioFiles: [URL], timePrefix: String, verbose: Bool) async -> [AudioRemixerInput] {
    var inputs: [AudioRemixerInput] = []
    let fm = FileManager.default

    // Find the earliest creation time to use as base
    var baseTime = Date.distantFuture
    for file in audioFiles {
        if let attrs = try? fm.attributesOfItem(atPath: file.path),
           let creationDate = attrs[.creationDate] as? Date
        {
            if creationDate < baseTime {
                baseTime = creationDate
            }
        }
    }

    if baseTime == Date.distantFuture {
        baseTime = Date()
    }

    for audioURL in audioFiles {
        guard let timingInfo = await buildTimingInfo(for: audioURL, baseTime: baseTime, timePrefix: timePrefix) else {
            if verbose { Logger.storage.debug("Skipping audio file (no timing info): \(audioURL.lastPathComponent, privacy: .public)") }
            continue
        }

        inputs.append(AudioRemixerInput(url: audioURL, timingInfo: timingInfo))
    }

    // Sort: system audio first, then mics by source ID
    inputs.sort { a, b in
        let aIsSystem = a.timingInfo.trackType.sourceID == "system"
        let bIsSystem = b.timingInfo.trackType.sourceID == "system"

        if aIsSystem && !bIsSystem { return true }
        if !aIsSystem && bIsSystem { return false }
        return a.timingInfo.trackType.sourceID < b.timingInfo.trackType.sourceID
    }

    return inputs
}

func buildTimingInfo(for audioURL: URL, baseTime: Date, timePrefix: String) async -> AudioTrackTimingInfo? {
    let fm = FileManager.default
    let asset = AVURLAsset(url: audioURL)

    // Get duration from asset
    guard let assetDuration = try? await asset.load(.duration),
          CMTimeGetSeconds(assetDuration) > 0
    else {
        return nil
    }

    // Get creation time for start offset
    let creationDate: Date
    if let attrs = try? fm.attributesOfItem(atPath: audioURL.path),
       let date = attrs[.creationDate] as? Date
    {
        creationDate = date
    } else {
        creationDate = baseTime
    }

    let startOffsetSeconds = max(0, creationDate.timeIntervalSince(baseTime))
    let startOffset = CMTime(seconds: startOffsetSeconds, preferredTimescale: 48000)
    let endOffset = CMTimeAdd(startOffset, assetDuration)

    // Parse track type from filename
    let trackType = parseTrackType(from: audioURL.lastPathComponent, timePrefix: timePrefix)

    return AudioTrackTimingInfo(
        startOffset: startOffset,
        endOffset: endOffset,
        trackType: trackType,
        hasAudio: true
    )
}

func parseTrackType(from filename: String, timePrefix: String) -> AudioTrackType {
    // Remove prefix and suffix: "143022_audio_" ... ".m4a"
    let prefix = "\(timePrefix)_audio_"
    let suffix = ".m4a"

    guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else {
        return .microphone(name: "Unknown", deviceUID: "unknown")
    }

    let deviceID = String(filename.dropFirst(prefix.count).dropLast(suffix.count))

    if deviceID == "system" {
        return .systemAudio
    } else {
        // Use device ID as both name and UID (we don't have the original name)
        return .microphone(name: deviceID, deviceUID: deviceID)
    }
}
