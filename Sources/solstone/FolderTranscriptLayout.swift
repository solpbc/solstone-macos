// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import CoreFoundation

/// Locally recognize conversation exports before offering their bytes to a journal.
enum FolderTranscriptLayout {
    static let structured: Set<String> = ["json", "csv", "tsv", "html"]
    static let maxBytes = 32 * 1024 * 1024

    static func recognizes(_ ext: String, data: Data?) -> Bool {
        if ext == "vtt" || ext == "srt" { return true }
        guard let data, data.count <= maxBytes else { return false }
        if ext == "json" { return json(data) }
        guard var text = String(data: data, encoding: .utf8), !text.contains("\0") else { return false }
        if text.first == "\u{feff}" { text.removeFirst() }
        switch ext {
        case "tsv":
            let lines = text.split(whereSeparator: \.isNewline)
            guard lines.count > 1, lines.count <= 200_001, lines.first == "start\tend\ttext" else { return false }
            return lines.dropFirst().allSatisfy { line in
                let cells = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard cells.count == 3, let start = UInt64(cells[0]), let end = UInt64(cells[1]) else { return false }
                return end >= start && end <= 2_592_000_999 && !cells[2].isEmpty && line.utf8.count <= 8192
            }
        case "csv":
            return fireflies(text)
        case "html":
            return telegramHTML(text)
        case "txt", "md", "markdown", "log":
            if namedTextExport(text) { return true }
            let roles = Set(["user", "assistant", "human", "system", "chatgpt", "claude", "gemini"])
            var speakers = Set<String>()
            for line in text.split(whereSeparator: \.isNewline).prefix(256) {
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let markers = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*"))
                let name = parts[0].trimmingCharacters(in: markers).lowercased()
                if roles.contains(name) && !parts[1].trimmingCharacters(in: markers).isEmpty {
                    speakers.insert(name)
                    if speakers.count >= 2 { return true }
                }
            }
            // Distinguish timestamped chat exports from ordinary notes with section labels.
            let pattern = #"(?m)^[\u200e\u200f]?(?:\d\d:\d\d:\d\d From [^\r\n:]{1,100} *:|\[\d{1,4}[-/\.]\d{1,2}[-/\.]\d{1,4},?\s+\d{1,2}:\d\d(?::\d\d)?(?:\s*[AP]M)?\]\s+[^:\r\n]{1,60}:|\d{1,2}[/\.]\d{1,2}[/\.]\d{2,4},?\s+\d{1,2}:\d\d(?:\s*[AP]M)? - [^:\r\n]{1,60}:|\d{4}-\d\d-\d\d \d\d:\d\d [^:\r\n]{1,60}:|\[\d\d:\d\d:\d\d\.\d{3} --> \d\d:\d\d:\d\d\.\d{3}\])"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) >= 2
        default:
            return false
        }
    }

    private static func namedTextExport(_ text: String) -> Bool {
        let border = String(repeating: "=", count: 62)
        let footer = "Transcribed by https://otter.ai"
        guard text.contains(" <") || text.contains(footer) || text.contains(border) else { return false }
        let lines = text.split(maxSplits: 200_000, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count >= 3, lines.count <= 200_000 else { return false }

        if lines.first == border, lines.count >= 9, lines[1].hasPrefix("Guild: "),
           lines[2].hasPrefix("Channel: "), lines.last == border, lines[lines.count - 3] == border,
           lines[lines.count - 2].hasPrefix("Exported "), lines[lines.count - 2].hasSuffix(" message(s)") {
            return lines[3..<(lines.count - 3)].contains { $0.hasPrefix("[") && $0.contains("] ") }
        }
        if lines.last == footer {
            let clock = #"^(?:[^:]{1,60}?\s{2,})?[0-9]{1,3}:[0-5][0-9](?::[0-5][0-9])?$"#
            var turns = 0
            var hasBody = false
            for line in lines.dropLast() {
                if line.range(of: clock, options: .regularExpression) != nil {
                    guard turns == 0 || hasBody else { return false }
                    turns += 1
                    hasBody = false
                } else {
                    guard turns > 0 else { return false }
                    hasBody = true
                }
            }
            return turns >= 2 && hasBody
        }
        let pattern = #"^[0-9]{2}:[0-9]{2}(?::[0-9]{2})?\s+<[ @+%~&]?([^>]{1,40})>\s+\S"#
        guard let irc = try? NSRegularExpression(pattern: pattern) else { return false }
        var speakers = Set<String>()
        var turns = 0
        for line in lines {
            if let match = irc.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let speaker = Range(match.range(at: 1), in: line) {
                speakers.insert(line[speaker].lowercased())
                turns += 1
            } else if !line.hasPrefix("--- ") && line.range(of: #"^[0-9]{2}:[0-9]{2} -!-"#, options: .regularExpression) == nil {
                return false
            }
        }
        return turns >= 3 && speakers.count >= 2
    }

    private static func json(_ bytes: Data) -> Bool {
        var depth = 0
        var quoted = false
        var escaped = false
        for byte in bytes {
            if escaped { escaped = false; continue }
            if quoted && byte == 92 { escaped = true; continue }
            if byte == 34 { quoted.toggle(); continue }
            if !quoted {
                if byte == 91 || byte == 123 { depth += 1 }
                if byte == 93 || byte == 125 { depth -= 1 }
                if depth < 0 || depth > 32 { return false }
            }
        }
        guard depth == 0, !quoted, let root = try? JSONSerialization.jsonObject(with: bytes) else { return false }
        typealias Row = [String: Any]
        func text(_ value: Any?) -> Bool {
            guard let string = value as? String else { return false }
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        func timed(_ row: Row, start: String, end: String, body: String, allowStrings: Bool = false) -> Bool {
            func seconds(_ field: Any?) -> Double? {
                if let number = field as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                    return number.doubleValue
                }
                if allowStrings, let string = field as? String { return Double(string) }
                return nil
            }
            guard let from = seconds(row[start]), let to = seconds(row[end]) else { return false }
            return from >= 0 && to >= from && text(row[body])
        }
        if let rows = root as? [Row], !rows.isEmpty, rows.count <= 200_000 {
            return rows.allSatisfy {
                $0["type"] is String && ($0["ts"] as? String)?.range(of: #"^\d{1,10}\.\d{6}$"#, options: .regularExpression) != nil
            } && rows.contains {
                $0["type"] as? String == "message" && text($0["text"]) &&
                    ($0["user"] is String || $0["bot_id"] is String || $0["team"] is String || $0["blocks"] is [Any] ||
                        $0["client_msg_id"] is String || $0["user_profile"] is Row)
            }
        }
        guard let obj = root as? Row else { return false }
        if let rows = obj["segments"] as? [Row], !rows.isEmpty, rows.count <= 200_000 {
            if obj["text"] is String,
               obj["language"] is String || rows.contains(where: { row in
                   row["speaker"] is String || (row["id"] as? String).flatMap(UUID.init(uuidString:)) != nil
               }) {
                return rows.allSatisfy { timed($0, start: "start", end: "end", body: "text") }
            }
            return (obj["version"] as? String)?.range(of: #"^\d+(?:\.\d+)+$"#, options: .regularExpression) != nil &&
                rows.allSatisfy { timed($0, start: "startTime", end: "endTime", body: "body", allowStrings: true) }
        }
        let types = ["personal_chat", "bot_chat", "private_group", "private_supergroup", "public_supergroup",
                     "private_channel", "public_channel", "saved_messages"]
        guard obj["chats"] == nil, obj["personal_information"] == nil,
              let rows = obj["messages"] as? [Row], !rows.isEmpty, rows.count <= 200_000,
              types.contains(obj["type"] as? String ?? "") || rows.contains(where: {
                  $0["date_unixtime"] != nil || $0["from_id"] is String || $0["text_entities"] is [Any]
              }) else { return false }
        return rows.allSatisfy { row in
            ["message", "service"].contains(row["type"] as? String ?? "") &&
                ((row["date"] as? String)?.range(of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d"#, options: .regularExpression) != nil ||
                 (row["date_unixtime"] as? String).flatMap(UInt64.init) != nil || row["date_unixtime"] is NSNumber)
        } && rows.contains { row in
            guard row["type"] as? String == "message" else { return false }
            if text(row["text"]) { return true }
            return (row["text"] as? [Any])?.contains { text($0) || text(($0 as? Row)?["text"]) } == true
        }
    }

    private static func fireflies(_ source: String) -> Bool {
        var header = false
        var spoke = false
        var row = [String]()
        var field = ""
        var quoted = false
        var index = source.startIndex
        func consumeRow() -> Bool {
            row.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
            field = ""
            defer { row.removeAll(keepingCapacity: true) }
            if row == [""] { return true }
            if !header {
                header = row.map { $0.lowercased() } == ["speaker", "start time", "end time", "sentence"]
                return header
            }
            guard row.count == 4, row[0].utf8.count <= 256 else { return false }
            func clock(_ string: String) -> Double? {
                guard string.range(of: #"^(?:[0-9]{1,3}:[0-5][0-9]|[0-5]?[0-9]):[0-5][0-9](?:\.[0-9]{1,3})?$"#,
                                   options: .regularExpression) != nil else { return nil }
                let parts = string.split(separator: ":", omittingEmptySubsequences: false)
                guard (2...3).contains(parts.count), let last = Double(parts.last ?? ""),
                      last >= 0, last < 60 else { return nil }
                var total = 0
                for part in parts.dropLast() {
                    guard let n = Int(part), n >= 0, n <= 2592000, total < 2592000 else { return nil }
                    total = total * 60 + n
                }
                return Double(total * 60) + last
            }
            guard let start = clock(row[1]), let end = clock(row[2]), end >= start else { return false }
            if !row[3].isEmpty { spoke = true }
            return true
        }
        while index < source.endIndex {
            let ch = source[index]
            index = source.index(after: index)
            if ch == "\"" {
                if quoted, index < source.endIndex, source[index] == "\"" {
                    field.append("\"")
                    index = source.index(after: index)
                } else {
                    quoted.toggle()
                }
            } else if ch == ",", !quoted {
                guard row.count < 3 else { return false }
                row.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
                field = ""
            } else if ch.isNewline && !quoted {
                guard consumeRow() else { return false }
            } else {
                field.append(ch)
            }
            if field.utf8.count > 8192 { return false }
        }
        return !quoted && consumeRow() && header && spoke
    }

    private static func telegramHTML(_ text: String) -> Bool {
        // Telegram Desktop nests these classed divs inside one another.
        let markup = text.replacingOccurrences(of: #"(?is)<!--.*?-->|<(script|style)\b[^>]*>.*?</\1\s*>"#,
                                                with: "", options: .regularExpression)
        let pattern = #"(?i)</div\s*>|<div\b[^>]{0,16384}>|[^<>]+"#
        guard let tokens = try? NSRegularExpression(pattern: pattern) else { return false }
        let source = markup as NSString
        var stack = [Int]()
        var found = false
        tokens.enumerateMatches(in: markup, range: NSRange(location: 0, length: source.length)) { m, _, stop in
            guard let m else { return }
            let token = source.substring(with: m.range)
            if token.lowercased().hasPrefix("</div") {
                _ = stack.popLast()
            } else if token.lowercased().hasPrefix("<div") {
                guard stack.count < 64 else { stop.pointee = true; return }
                let match = token.range(of: #"(?i)\sclass\s*=\s*(?:"[^"]*"|'[^']*')"#, options: .regularExpression)
                let classes = match.map { Set(token[$0].split(whereSeparator: { $0 == "\"" || $0 == "'" })
                    .dropFirst().first?.split(whereSeparator: \.isWhitespace).map(String.init) ?? []) } ?? []
                var depth = stack.last ?? 0
                if depth == 0 && classes.isSuperset(of: ["page_body", "chat_page"]) { depth = 1 }
                else if depth == 1 && classes.contains("history") { depth = 2 }
                else if depth == 2 && classes.isSuperset(of: ["message", "default"]) { depth = 3 }
                else if depth == 3 && classes.contains("text") { depth = 4 }
                stack.append(depth)
            } else if stack.last == 4 && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                found = true
            }
        }
        return found && stack.isEmpty
    }
}
