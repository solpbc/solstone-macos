// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

enum AXContract {
    static let idPattern = #"^(journal)(\.[a-z][a-zA-Z0-9-]*)+$"#
    static let tokenPattern = #"^[a-z][a-z_]*$"#

    private static let generatedMarker =
        "DO NOT EDIT. Generated from Sources/journal/AXID.swift + AXToken.swift. Run `make ax-contract` to regenerate; `make ci` fails on drift."

    static let staticIDs: [String] = [
        AXID.Journal.Home.markCard,
        AXID.Journal.Home.nameState,
        AXID.Journal.Home.runDisplayGlanceState,
        AXID.Journal.Home.openJournal,
        AXID.Journal.Home.unconfiguredMessageState,
        AXID.Journal.Pane.nameField,
        AXID.Journal.Pane.nameSave,
        AXID.Journal.Pane.locationPathState,
        AXID.Journal.Pane.diskUsageState,
        AXID.Journal.RunState.start,
        AXID.Journal.RunState.stop,
        AXID.Journal.RunState.restart,
        AXID.Journal.RunState.displayState,
        AXID.Journal.RunState.blockedReasonState,
        AXID.Journal.RunState.healthState,
        AXID.Journal.RunState.runtimeVersionState,
        AXID.Journal.RunState.appVersionState,
        AXID.Journal.Backup.openBackup,
        AXID.Journal.Backup.messageState,
        AXID.Journal.Startup.launchAtLogin,
        AXID.Journal.Startup.launchAtLoginState
    ]

    static var enumerableIDs: [String] {
        var ids = staticIDs
        for pane in JournalPane.allCases {
            ids.append(AXID.Journal.Sidebar.tab(pane))
            ids.append(AXID.Journal.Sidebar.tabState(pane))
        }
        return ids
    }

    static var parameterizedTemplates: [ParameterizedIdentifier] {
        [
            ParameterizedIdentifier(
                template: "journal.sidebar.tab.{pane}",
                key: "JournalPane.rawValue",
                expansions: JournalPane.allCases.map(\.rawValue)
            ),
            ParameterizedIdentifier(
                template: "journal.sidebar.tab.{pane}.state",
                key: "JournalPane.rawValue",
                expansions: JournalPane.allCases.map(\.rawValue)
            )
        ].sorted { $0.template < $1.template }
    }

    static var vocabularies: [String: [String]] {
        [
            "JournalSidebarTabState": JournalSidebarTabState.axTokens,
            "JournalRunDisplay": JournalRunDisplay.axTokens,
            "JournalHealthDisplay": JournalHealthDisplay.axTokens,
            "JournalEnabledState": JournalEnabledState.axTokens
        ]
    }

    static var states: [String: StateBinding] {
        [
            "journal.sidebar.tab.{pane}.state": .enum("JournalSidebarTabState"),
            AXID.Journal.Home.nameState: .freeform,
            AXID.Journal.Home.runDisplayGlanceState: .enum("JournalRunDisplay"),
            AXID.Journal.Home.unconfiguredMessageState: .freeform,
            AXID.Journal.Pane.locationPathState: .freeform,
            AXID.Journal.Pane.diskUsageState: .numeric,
            AXID.Journal.RunState.displayState: .enum("JournalRunDisplay"),
            AXID.Journal.RunState.blockedReasonState: .freeform,
            AXID.Journal.RunState.healthState: .enum("JournalHealthDisplay"),
            AXID.Journal.RunState.runtimeVersionState: .freeform,
            AXID.Journal.RunState.appVersionState: .freeform,
            AXID.Journal.Backup.messageState: .freeform,
            AXID.Journal.Startup.launchAtLoginState: .enum("JournalEnabledState")
        ]
    }

    static var requiredStateKeys: Set<String> {
        Set(
            enumerableIDs
                .filter { $0.hasSuffix(".state") }
                .map(stateKey(for:))
        )
    }

    static func stateKey(for id: String) -> String {
        if id.hasPrefix("journal.sidebar.tab."), id.hasSuffix(".state") {
            return "journal.sidebar.tab.{pane}.state"
        }
        return id
    }

    static func generate() -> String {
        let contract = Contract(
            generated: generatedMarker,
            version: 1,
            grammar: Grammar(identifier: idPattern, token: tokenPattern),
            surfaces: ["journal"],
            vocabularies: vocabularies,
            identifiers: IdentifierSet(
                staticIDs: staticIDs.sorted(),
                parameterized: parameterizedTemplates
            ),
            states: states
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try! encoder.encode(contract)
        return String(data: data, encoding: .utf8)! + "\n"
    }
}

struct ParameterizedIdentifier: Codable, Equatable {
    let template: String
    let key: String
    let expansions: [String]?
    let runtime: Bool?

    init(template: String, key: String, expansions: [String]) {
        self.template = template
        self.key = key
        self.expansions = expansions
        self.runtime = nil
    }
}

struct StateBinding: Codable, Equatable {
    enum Kind: String, Codable {
        case `enum`
        case numeric
        case freeform
    }

    let kind: Kind
    let vocabulary: String?

    static func `enum`(_ vocabulary: String) -> StateBinding {
        StateBinding(kind: .enum, vocabulary: vocabulary)
    }

    static let numeric = StateBinding(kind: .numeric, vocabulary: nil)
    static let freeform = StateBinding(kind: .freeform, vocabulary: nil)
}

private struct Contract: Codable {
    let generated: String
    let version: Int
    let grammar: Grammar
    let surfaces: [String]
    let vocabularies: [String: [String]]
    let identifiers: IdentifierSet
    let states: [String: StateBinding]

    enum CodingKeys: String, CodingKey {
        case generated = "_generated"
        case version
        case grammar
        case surfaces
        case vocabularies
        case identifiers
        case states
    }
}

private struct Grammar: Codable {
    let identifier: String
    let token: String
}

private struct IdentifierSet: Codable {
    let staticIDs: [String]
    let parameterized: [ParameterizedIdentifier]

    enum CodingKeys: String, CodingKey {
        case staticIDs = "static"
        case parameterized
    }
}
