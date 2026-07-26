// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing

@Suite("SolChat notification delegate wire-up")
struct SolChatNotificationDelegateWireUpTests {
    @Test func delegateRoutesUpdateNamespaceToSettingsAndOtherIdentifiersToSolChat() throws {
        let source = try readWireUpSource("Sources/solstone/SolChatBridge.swift")
        let references = [
            "switch userNotificationClickDestination(for: id)",
            "case .updatesSettings:",
            #"state.pendingSettingsTab = "updates""#,
            "NotificationCenter.default.post(name: .openSettingsWindow, object: nil)",
            "NSApp.activate(ignoringOtherApps: true)",
            "case .solChat(let requestID):",
            "handleClick(requestID: requestID)"
        ]

        for reference in references {
            #expect(wireUpContains(source, reference))
        }
    }
}
