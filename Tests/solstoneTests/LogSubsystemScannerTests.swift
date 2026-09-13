// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore
import Testing
@testable import solstone

@Suite("LogSubsystemScanner")
struct LogSubsystemScannerTests {
    @Test func sourcesWalkPassesAgainstAllForPersistedHelp() throws {
        let files = try sourceSwiftFiles()
        let result = scanLogSubsystemConstructions(files)
        #expect(result.ok, "\(result.failures.joined(separator: "\n"))")
    }

    @Test func unknownSubsystemLiteralFails() {
        let result = scanLogSubsystemConstructions([
            (
                path: "fixture.swift",
                contents: """
                import os
                let log = Logger(subsystem: "app.solstone.not-a-real-subsystem", category: "x")
                """
            )
        ])
        #expect(!result.ok)
        #expect(result.failures.contains { $0.contains("app.solstone.not-a-real-subsystem") })
    }

    @Test func unknownSolstoneLogSubsystemMemberFails() {
        let result = scanLogSubsystemConstructions([
            (
                path: "fixture.swift",
                contents: """
                import os
                let log = Logger(subsystem: SolstoneLogSubsystem.notInTheHelpSet, category: "x")
                """
            )
        ])
        #expect(!result.ok)
        #expect(result.failures.contains { $0.contains("notInTheHelpSet") })
    }

    @Test func emptyFileListFails() {
        let result = scanLogSubsystemConstructions([])
        #expect(!result.ok)
    }

    @Test func filesWithNoConstructionsFail() {
        let result = scanLogSubsystemConstructions([
            (path: "empty.swift", contents: "import Foundation\nstruct Foo {}\n")
        ])
        #expect(!result.ok)
    }
}

struct LogSubsystemScanResult {
    var ok: Bool
    var failures: [String]
    var constructionCount: Int
}

func scanLogSubsystemConstructions(_ files: [(path: String, contents: String)]) -> LogSubsystemScanResult {
    if files.isEmpty {
        return LogSubsystemScanResult(ok: false, failures: ["empty file list"], constructionCount: 0)
    }

    let allowed = Set(SolstoneLogSubsystem.allForPersistedHelp)
    var failures: [String] = []
    var constructionCount = 0

    for file in files {
        let bindings = logSubsystemBindings(in: file.contents)
        let expressions = logSubsystemExpressions(in: file.contents)
        constructionCount += expressions.count
        for expression in expressions {
            if !logSubsystemExpressionIsAllowed(expression, bindings: bindings, allowedLiterals: allowed) {
                failures.append("\(file.path): unrecognized or disallowed subsystem \(expression)")
            }
        }
    }

    if constructionCount == 0 {
        failures.append("zero constructions")
    }

    return LogSubsystemScanResult(ok: failures.isEmpty, failures: failures, constructionCount: constructionCount)
}

func sourceSwiftFiles() throws -> [(path: String, contents: String)] {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sources = repoRoot.appendingPathComponent("Sources", isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(
        at: sources,
        includingPropertiesForKeys: nil
    ) else {
        throw NSError(domain: "LogSubsystemScanner", code: 1)
    }
    var files: [(path: String, contents: String)] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
        let contents = try String(contentsOf: url, encoding: .utf8)
        files.append((path: url.path, contents: contents))
    }
    return files
}

func logSubsystemBindings(in source: String) -> [String: String] {
    let pattern = #"let\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(SolstoneLogSubsystem\.[A-Za-z_][A-Za-z0-9_]*|WatchdogProduct\.[A-Za-z_][A-Za-z0-9_]*\.loggerSubsystem)"#
    let regex = try! NSRegularExpression(pattern: pattern)
    let range = NSRange(source.startIndex..<source.endIndex, in: source)
    var bindings: [String: String] = [:]
    for match in regex.matches(in: source, range: range) {
        guard let nameRange = Range(match.range(at: 1), in: source),
              let valueRange = Range(match.range(at: 2), in: source) else {
            continue
        }
        bindings[String(source[nameRange])] = String(source[valueRange])
    }
    return bindings
}

func logSubsystemExpressions(in source: String) -> [String] {
    logSubsystemCallArguments(in: source, marker: "Logger(subsystem:")
        + logSubsystemCallArguments(in: source, marker: "SPLLogging.configure(subsystem:")
}

func logSubsystemCallArguments(in source: String, marker: String) -> [String] {
    var results: [String] = []
    var searchStart = source.startIndex
    while let range = source.range(of: marker, range: searchStart..<source.endIndex) {
        var index = range.upperBound
        while index < source.endIndex, source[index].isWhitespace {
            source.formIndex(after: &index)
        }
        let start = index
        var depth = 0
        var inString = false
        var end = start
        while index < source.endIndex {
            let character = source[index]
            if inString {
                if character == "\\" {
                    source.formIndex(after: &index)
                    if index < source.endIndex {
                        source.formIndex(after: &index)
                    }
                    continue
                }
                if character == "\"" {
                    inString = false
                }
                source.formIndex(after: &index)
                continue
            }
            if character == "\"" {
                inString = true
                source.formIndex(after: &index)
                continue
            }
            if character == "(" {
                depth += 1
                source.formIndex(after: &index)
                continue
            }
            if character == ")" {
                if depth == 0 {
                    end = index
                    break
                }
                depth -= 1
                source.formIndex(after: &index)
                continue
            }
            if character == "," && depth == 0 {
                end = index
                break
            }
            source.formIndex(after: &index)
        }
        results.append(String(source[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
        searchStart = index
    }
    return results
}

func logSubsystemExpressionIsAllowed(
    _ expression: String,
    bindings: [String: String],
    allowedLiterals: Set<String>
) -> Bool {
    if let literal = logSubsystemStringLiteral(expression) {
        return allowedLiterals.contains(literal)
    }
    if let member = solstoneLogSubsystemMember(expression) {
        guard let value = solstoneLogSubsystemValue(forMember: member) else {
            return false
        }
        return allowedLiterals.contains(value)
    }
    if let value = watchdogProductLoggerSubsystemValue(expression) {
        return allowedLiterals.contains(value)
    }
    if expression.range(
        of: #"^[A-Za-z_][A-Za-z0-9_]*\.loggerSubsystem$"#,
        options: .regularExpression
    ) != nil {
        return true
    }
    if let bound = bindings[expression] {
        return logSubsystemExpressionIsAllowed(bound, bindings: [:], allowedLiterals: allowedLiterals)
    }
    return false
}

func logSubsystemStringLiteral(_ expression: String) -> String? {
    guard expression.hasPrefix("\""), expression.hasSuffix("\""), expression.count >= 2 else {
        return nil
    }
    return String(expression.dropFirst().dropLast())
}

func solstoneLogSubsystemMember(_ expression: String) -> String? {
    let prefix = "SolstoneLogSubsystem."
    guard expression.hasPrefix(prefix) else {
        return nil
    }
    let member = String(expression.dropFirst(prefix.count))
    guard !member.isEmpty else {
        return nil
    }
    return member
}

func solstoneLogSubsystemValue(forMember member: String) -> String? {
    switch member {
    case "observer":
        return SolstoneLogSubsystem.observer
    case "journal":
        return SolstoneLogSubsystem.journal
    case "observerSPL":
        return SolstoneLogSubsystem.observerSPL
    case "watchdog":
        return SolstoneLogSubsystem.watchdog
    default:
        return nil
    }
}

func watchdogProductLoggerSubsystemValue(_ expression: String) -> String? {
    let prefix = "WatchdogProduct."
    let suffix = ".loggerSubsystem"
    guard expression.hasPrefix(prefix), expression.hasSuffix(suffix) else {
        return nil
    }
    let product = String(expression.dropFirst(prefix.count).dropLast(suffix.count))
    switch product {
    case "observer":
        return WatchdogProduct.observer.loggerSubsystem
    case "journal":
        return WatchdogProduct.journal.loggerSubsystem
    default:
        return nil
    }
}
