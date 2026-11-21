// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

struct SourceDeclaration: Codable, Equatable, Sendable {
    let source: String
    let state: String
    var detail: String? = nil
}

struct SharedSourceSnapshot: Codable, Equatable, Sendable {
    struct Source: Codable, Equatable, Sendable {
        let source: String
        let detail: String?
        let state: String?
        let origin: String
        let declared_at: String?
        let last_synced_at: String?
    }

    struct Device: Codable, Equatable, Sendable {
        let cid: String
        let display_label: String
        let device_type: String?
        let device_last_seen_at: String?
        let sources: [Source]
    }

    let self_cid: String?
    let sources_rev: String
    let devices: [Device]

    var otherObsidianDevices: [SharedSourceDevice] {
        // These reads use the paired door. An unidentified caller cannot exclude itself.
        guard let self_cid else { return [] }
        var seen = Set<String>()
        return devices.compactMap { device -> SharedSourceDevice? in
            guard device.cid != self_cid, seen.insert(device.cid).inserted else { return nil }
            let rows = device.sources.compactMap { source -> SharedSourceDetail? in
                guard source.source == "obsidian" else { return nil }
                let time: Date?
                switch source.origin {
                case "observed":
                    time = Self.date(source.last_synced_at)
                case "declared" where ["on", "paused", "needs_attention"].contains(source.state ?? ""):
                    time = [source.last_synced_at, source.declared_at, device.device_last_seen_at]
                        .compactMap(Self.date).max()
                default: return nil
                }
                return .init(detail: source.detail, state: source.state, time: time)
            }.sorted {
                if $0.time != $1.time { return ($0.time ?? .distantPast) > ($1.time ?? .distantPast) }
                return ($0.detail ?? "") < ($1.detail ?? "")
            }
            guard !rows.isEmpty else { return nil }
            return .init(id: device.cid, name: device.display_label, type: device.device_type, rows: rows)
        }.sorted {
            if $0.rows[0].time != $1.rows[0].time {
                return ($0.rows[0].time ?? .distantPast) > ($1.rows[0].time ?? .distantPast)
            }
            return ($0.name, $0.id) < ($1.name, $1.id)
        }
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle().parse(value))
    }
}

struct SharedSourceDevice: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let type: String?
    let rows: [SharedSourceDetail]
}

struct SharedSourceDetail: Equatable, Sendable {
    let detail: String?
    let state: String?
    let time: Date?
}
