// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreFoundation
import Foundation
import os
import SolstoneCore

internal struct JournalDirectDoorPortResolution: Equatable, Sendable {
    let port: Int
    let provenance: JournalDirectDoorPortProvenance
}

internal enum JournalDirectDoorPortProvenance: Equatable, Sendable {
    case normalDefault
    case configured
    case degraded(reason: JournalDirectDoorPortDegradationReason)
}

internal enum JournalDirectDoorPortDegradationReason: String, Equatable, Sendable {
    case configUnreadable = "config-unreadable"
    case invalidJSON = "invalid-json"
    case rootNotObject = "root-not-object"
    case pairingNull = "pairing-null"
    case pairingNotObject = "pairing-not-object"
    case directPortNull = "direct-port-null"
    case directPortWrongType = "direct-port-wrong-type"
    case directPortZero = "direct-port-zero"
    case directPortOutOfRange = "direct-port-out-of-range"
}

internal enum JournalLifecyclePortPreflight {
    static let defaultDirectDoorPort = 7657
    static let conveyPort = 5015

    static func orderedPorts(for resolution: JournalDirectDoorPortResolution) -> [Int] {
        [resolution.port, conveyPort]
    }
}

internal func resolveJournalDirectDoorPort(journalRoot: URL) -> JournalDirectDoorPortResolution {
    let resolution = classifyJournalDirectDoorPort(journalRoot: journalRoot)
    if case .degraded(let reason) = resolution.provenance {
        let message = journalDirectDoorPortDegradationMessage(
            reason: reason,
            fallbackPort: JournalLifecyclePortPreflight.defaultDirectDoorPort
        )
        Logger.setup.warning("\(message, privacy: .public)")
    }
    return resolution
}

internal func journalDirectDoorPortDegradationMessage(
    reason: JournalDirectDoorPortDegradationReason,
    fallbackPort: Int
) -> String {
    "journal-lifecycle: paired-direct-door-port-degraded reason=\(reason.rawValue) fallbackPort=\(fallbackPort)"
}

private func classifyJournalDirectDoorPort(journalRoot: URL) -> JournalDirectDoorPortResolution {
    let configURL = journalRoot
        .appendingPathComponent("config", isDirectory: true)
        .appendingPathComponent("journal.json", isDirectory: false)
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: configURL.path) else {
        return normalDefaultResolution()
    }

    let data: Data
    do {
        data = try Data(contentsOf: configURL)
    } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
        return fileManager.fileExists(atPath: configURL.path)
            ? degradedResolution(.configUnreadable)
            : normalDefaultResolution()
    } catch {
        return degradedResolution(.configUnreadable)
    }

    let root: [String: Any]
    do {
        guard let decoded = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            return degradedResolution(.rootNotObject)
        }
        root = decoded
    } catch {
        return degradedResolution(.invalidJSON)
    }

    guard let pairingValue = root["pairing"] else {
        return normalDefaultResolution()
    }
    guard !(pairingValue is NSNull) else {
        return degradedResolution(.pairingNull)
    }
    guard let pairing = pairingValue as? [String: Any] else {
        return degradedResolution(.pairingNotObject)
    }

    guard let directPortValue = pairing["direct_port"] else {
        return normalDefaultResolution()
    }
    guard !(directPortValue is NSNull) else {
        return degradedResolution(.directPortNull)
    }
    guard let directPortNumber = directPortValue as? NSNumber,
          CFGetTypeID(directPortNumber) != CFBooleanGetTypeID(),
          isIntegerCFNumber(directPortNumber) else {
        return degradedResolution(.directPortWrongType)
    }

    if directPortNumber.compare(NSNumber(value: 0)) == .orderedSame {
        return degradedResolution(.directPortZero)
    }
    guard directPortNumber.compare(NSNumber(value: 1)) != .orderedAscending,
          directPortNumber.compare(NSNumber(value: 65_535)) != .orderedDescending else {
        return degradedResolution(.directPortOutOfRange)
    }

    return JournalDirectDoorPortResolution(port: directPortNumber.intValue, provenance: .configured)
}

private func normalDefaultResolution() -> JournalDirectDoorPortResolution {
    JournalDirectDoorPortResolution(
        port: JournalLifecyclePortPreflight.defaultDirectDoorPort,
        provenance: .normalDefault
    )
}

private func degradedResolution(_ reason: JournalDirectDoorPortDegradationReason) -> JournalDirectDoorPortResolution {
    JournalDirectDoorPortResolution(
        port: JournalLifecyclePortPreflight.defaultDirectDoorPort,
        provenance: .degraded(reason: reason)
    )
}

private func isIntegerCFNumber(_ number: NSNumber) -> Bool {
    switch CFNumberGetType(number) {
    case .sInt8Type,
         .sInt16Type,
         .sInt32Type,
         .sInt64Type,
         .charType,
         .shortType,
         .intType,
         .longType,
         .longLongType,
         .cfIndexType,
         .nsIntegerType:
        return true
    default:
        return false
    }
}
