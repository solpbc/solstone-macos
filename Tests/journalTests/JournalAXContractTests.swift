// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import journal

@Suite("AXContract-journal", .serialized)
struct JournalAXContractTests {
    private let contractPath = "journal-ax-contract.json"

    @Test func contractMatchesCommittedFileOrRegenerates() throws {
        let generated = AXContract.generate()
        if ProcessInfo.processInfo.environment["AX_CONTRACT_REGEN"] == "1" {
            try generated.write(
                to: URL(fileURLWithPath: contractPath),
                atomically: true,
                encoding: .utf8
            )
            return
        }

        guard let committed = try? String(contentsOfFile: contractPath, encoding: .utf8) else {
            Issue.record("journal-ax-contract.json is missing or unreadable; run `make ax-contract` and commit.")
            return
        }

        if committed != generated {
            Issue.record("journal-ax-contract.json is stale vs the Swift SoT; run `make ax-contract` and commit.")
        }
        #expect(committed == generated)
    }

    @Test func generateIsIdempotent() {
        #expect(AXContract.generate() == AXContract.generate())
    }

    @Test func stateMapKeysMatchEnumerableStateIDs() {
        let actual = Set(AXContract.states.keys)
        let expected = AXContract.requiredStateKeys
        let missing = expected.subtracting(actual).sorted()
        let extra = actual.subtracting(expected).sorted()

        if !missing.isEmpty {
            Issue.record("missing state bindings: \(missing.joined(separator: ", "))")
        }
        if !extra.isEmpty {
            Issue.record("extra state bindings: \(extra.joined(separator: ", "))")
        }

        #expect(missing.isEmpty)
        #expect(extra.isEmpty)
    }

    @Test func staticAXIDLeavesAreRegisteredInContract() throws {
        let root = URL(fileURLWithPath: "Sources/journal", isDirectory: true)
        let axidURL = root.appendingPathComponent("AXID.swift")
        let source = try String(contentsOf: axidURL, encoding: .utf8)
        let registered = Set(AXContract.enumerableIDs)
        let missing = staticAXIDLeaves(in: source)
            .filter { !registered.contains($0.literal) }

        if !missing.isEmpty {
            let message = missing
                .map { "\($0.literal) (\($0.name))" }
                .joined(separator: ", ")
            Issue.record("AXID static identifiers missing from AXContract.enumerableIDs: \(message)")
        }
        #expect(missing.isEmpty)
    }

    @Test func enumStateVocabulariesExist() {
        let vocabularyNames = Set(AXContract.vocabularies.keys)
        var missing: [String] = []

        for (stateID, binding) in AXContract.states where binding.kind == .enum {
            guard let vocabulary = binding.vocabulary else {
                missing.append("\(stateID): <nil>")
                continue
            }
            if !vocabularyNames.contains(vocabulary) {
                missing.append("\(stateID): \(vocabulary)")
            }
        }

        if !missing.isEmpty {
            Issue.record("missing vocabularies: \(missing.joined(separator: ", "))")
        }
        #expect(missing.isEmpty)
    }

    private func staticAXIDLeaves(in source: String) -> [(name: String, literal: String)] {
        let pattern = #"static\s+let\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"([^"]+)""#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: source),
                  let literalRange = Range(match.range(at: 2), in: source)
            else {
                return nil
            }
            let literal = String(source[literalRange])
            guard literal.range(of: AXContract.idPattern, options: .regularExpression) != nil else {
                return nil
            }
            return (name: String(source[nameRange]), literal: literal)
        }
    }
}
