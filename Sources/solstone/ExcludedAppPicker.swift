// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore

/// Availability state of the open-apps picker
public enum ExcludedAppPickerAvailability: String, CaseIterable, Equatable, Sendable {
    case needsScreenRecording
    case nothingAvailable
    case ready

    public var axToken: String {
        switch self {
        case .needsScreenRecording:
            return "needs_screen_recording"
        case .nothingAvailable:
            return "nothing_available"
        case .ready:
            return "ready"
        }
    }
}

/// Helper for extracting candidate application names and evaluating picker availability
public enum ExcludedAppPicker {
    /// Appends an application name to the excluded apps list if valid and not already present.
    /// - Parameters:
    ///   - name: The raw application name to add.
    ///   - apps: The current list of excluded app entries.
    /// - Returns: A new array of `AppEntry` with the app appended, or `apps` if skipped.
    public static func appending(_ name: String, to apps: [AppEntry]) -> [AppEntry] {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return apps }
        guard !apps.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) else { return apps }

        let slug = trimmed.lowercased().replacingOccurrences(of: " ", with: "-")
        var result = apps
        result.append(AppEntry(bundleID: "user.excluded.\(slug)", name: trimmed))
        return result
    }

    /// Evaluates the picker state and returns available candidate names.
    /// - Parameters:
    ///   - screenRecordingGranted: Whether screen recording permission is granted
    ///   - records: On-screen window records to inspect
    ///   - alreadyExcludedNames: App names currently in the exclusion list
    /// - Returns: A tuple containing the availability state and sorted candidate names.
    public static func evaluate(
        screenRecordingGranted: Bool,
        records: [OnScreenWindowRecord],
        alreadyExcludedNames: [String]
    ) -> (availability: ExcludedAppPickerAvailability, candidateNames: [String]) {
        guard screenRecordingGranted else {
            return (.needsScreenRecording, [])
        }

        let excludedSet = Set(alreadyExcludedNames.map { $0.lowercased() })
        var seen = Set<String>()
        var candidates: [String] = []

        for record in records {
            let name = record.ownerName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let lower = name.lowercased()
            if !excludedSet.contains(lower) && !seen.contains(lower) {
                seen.insert(lower)
                candidates.append(name)
            }
        }

        candidates.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        if candidates.isEmpty {
            return (.nothingAvailable, [])
        } else {
            return (.ready, candidates)
        }
    }
}
