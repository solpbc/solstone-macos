import AppKit
import Foundation
import OSLog
import SolstoneCore
import SwiftUI
import Testing
import UpdateKit
@testable import solstone

@Suite("SettingsView")
struct SettingsViewTests {
    @Test func configuredJournalPanelWiresAffordancesFromRemedy() throws {
        let source = try readWireUpSource("Sources/solstone/SettingsView.swift")
        #expect(wireUpContains(source, "journalPanelAffordances(for:"))
        #expect(wireUpContains(source, "affordances.showOpenJournal"))
        #expect(wireUpContains(source, "appState.requestOpenJournal(.root)"))
        #expect(wireUpContains(source, "affordances.showRelink"))
        #expect(wireUpContains(source, "affordances.showTunnelRetry"))
        #expect(wireUpContains(source, "affordances.showPairingForm"))
    }

    @Test func tabRawValuesMatchCaseNames() {
        #expect(SettingsView.Tab.permissions.rawValue == "permissions")
        #expect(SettingsView.Tab.observer.rawValue == "observer")
        #expect(SettingsView.Tab.service.rawValue == "service")
        #expect(SettingsView.Tab.microphones.rawValue == "microphones")
        #expect(SettingsView.Tab.privacy.rawValue == "privacy")
        #expect(SettingsView.Tab.status.rawValue == "status")
        #expect(SettingsView.Tab.updates.rawValue == "updates")
        #expect(SettingsView.Tab.help.rawValue == "help")
    }

    @Test func journalConnectionRecoveryActionMapping() {
        #expect(journalConnectionRecoveryAction(for: nil) == .none)
        #expect(journalConnectionRecoveryAction(for: .keychainUnavailable) == .reevaluatePairing)
        #expect(journalConnectionRecoveryAction(for: .noRoute) == .reevaluatePairing)
        #expect(journalConnectionRecoveryAction(for: .unreachable(nil)) == .coalescedReconnect)
        #expect(journalConnectionRecoveryAction(for: .unreachable("timeout")) == .coalescedReconnect)
        #expect(journalConnectionRecoveryAction(for: .loopbackUnavailable) == .coalescedReconnect)
        #expect(journalConnectionRecoveryAction(for: .notEntitled) == .paidPlan)
        #expect(journalConnectionRecoveryAction(for: .revoked) == .retryRevokedRetirement)
        #expect(journalConnectionRecoveryAction(for: .mismatch) == .mismatchFreshLinkAndSupport)
        #expect(journalConnectionRecoveryAction(for: .notServing) == .none)
    }

    @Test func shouldShowPairingRetryPredicate() {
        #expect(shouldShowPairingRetry(for: .error(.keychainUnavailable)))
        #expect(shouldShowPairingRetry(for: .error(.loopbackUnavailable)))
        #expect(shouldShowPairingRetry(for: .error(.revoked)))
        #expect(!shouldShowPairingRetry(for: .error(.notEntitled)))
        #expect(!shouldShowPairingRetry(for: .disconnected))
        #expect(shouldShowPairingRetry(for: .disconnected, failureCause: .unreachable(nil)))
        #expect(shouldShowPairingRetry(for: .error(.revoked), failureCause: .revoked))
        #expect(!shouldShowPairingRetry(for: .error(.notEntitled), failureCause: .notEntitled))
        #expect(!shouldShowPairingRetry(for: .disconnected, failureCause: .mismatch))
    }

    @Test @MainActor func settingsViewAcceptsInjectedOpenURL() {
        var openedURLs: [URL] = []
        let customOpenURL: @MainActor (URL) -> Bool = { url in
            openedURLs.append(url)
            return true
        }

        let state = AppState.forSnapshot()
        let updateController = UpdateController(
            feedURL: nil,
            publicKey: nil,
            log: .setup,
            errorDomain: "app.solstone.observer.updates",
            defaults: .standard
        ) { _, _ in nil }
        _ = SettingsView(appState: state, updateController: updateController, openURL: customOpenURL)
        #expect(openedURLs.isEmpty)
    }

    @Test @MainActor func connectionVerdictCaptionsPinned() {
        let notEntitled = TunnelLifecycleOwner.reduceConnectionVerdict(
            state: .error(.notEntitled),
            hasPersistedPairing: true,
            isTunnelManaged: true,
            supervisorAttemptState: .idle,
            isProxyStarting: false,
            establishedLoopbackPort: nil,
            hasTransport: false
        )
        #expect(notEntitled.caption != nil)
        #expect(notEntitled.caption == "your journal is paired, but it isn't on the paid plan, so it can't sync over the internet. on the same wi-fi as your journal, or over your own vpn, it connects directly without the plan.")

        let noRoute = TunnelLifecycleOwner.reduceConnectionVerdict(
            state: .disconnected,
            hasPersistedPairing: true,
            isTunnelManaged: false,
            supervisorAttemptState: .idle,
            isProxyStarting: false,
            establishedLoopbackPort: nil,
            hasTransport: false
        )
        #expect(noRoute.caption != nil)
        #expect(noRoute.caption == "waiting for a direct network route or relay connection")

        let unreachable = TunnelLifecycleOwner.reduceConnectionVerdict(
            state: .disconnected,
            hasPersistedPairing: true,
            isTunnelManaged: true,
            supervisorAttemptState: .idle,
            isProxyStarting: false,
            establishedLoopbackPort: nil,
            hasTransport: false
        )
        #expect(unreachable.caption == nil)

        let loopback = TunnelLifecycleOwner.reduceConnectionVerdict(
            state: .error(.loopbackUnavailable),
            hasPersistedPairing: true,
            isTunnelManaged: true,
            supervisorAttemptState: .idle,
            isProxyStarting: false,
            establishedLoopbackPort: nil,
            hasTransport: false
        )
        #expect(loopback.caption == nil)

        let revoked = TunnelLifecycleOwner.reduceConnectionVerdict(
            state: .error(.revoked),
            hasPersistedPairing: true,
            isTunnelManaged: true,
            supervisorAttemptState: .idle,
            isProxyStarting: false,
            establishedLoopbackPort: nil,
            hasTransport: false
        )
        #expect(revoked.caption == nil)

        let keychain = TunnelLifecycleOwner.reduceConnectionVerdict(
            state: .error(.keychainUnavailable),
            hasPersistedPairing: true,
            isTunnelManaged: true,
            supervisorAttemptState: .idle,
            isProxyStarting: false,
            establishedLoopbackPort: nil,
            hasTransport: false
        )
        #expect(keychain.caption == nil)
    }

    @Test @MainActor func hostedSettingsViewSingleJournalConnectionStateNodeAcrossConfigurations() {
        let updateController = UpdateController(
            feedURL: nil,
            publicKey: nil,
            log: .setup,
            errorDomain: "app.solstone.observer.updates",
            defaults: .standard
        ) { _, _ in nil }

        let configuredConfig = AppConfig(
            serverURL: "https://example.com",
            serverKey: "secret",
            journalPath: NSTemporaryDirectory()
        )

        // 1. Configured
        let configuredApp = AppState.forSnapshot(config: configuredConfig, initialTunnelPairing: pairing())
        configuredApp.pendingSettingsTab = SettingsView.Tab.service.rawValue
        let configuredView = SettingsView(
            appState: configuredApp,
            updateController: updateController,
            selectedTab: .service
        )
        let configuredHost = makeHostedSettingsView(configuredView)
        let allNodes = findAccessibilityNodes(in: configuredHost)
        let configuredNodes = allNodes
            .filter { $0.identifier == AXID.Settings.Service.journalConnectionState }
        if !allNodes.isEmpty {
            #expect(configuredNodes.count == 1)
            if !configuredNodes.isEmpty {
                #expect(configuredNodes[0].value == configuredApp.tunnelLifecycleOwner.connectionVerdict.axToken)
            }
        }
        #expect(configuredApp.tunnelLifecycleOwner.connectionVerdict.axToken == PairingConnectionAXState.unreachable.axToken)

        // 2. Unconfigured with pairing flow
        let unconfiguredApp = AppState.forSnapshot(initialTunnelPairing: pairing())
        unconfiguredApp.pendingSettingsTab = SettingsView.Tab.service.rawValue
        let unconfiguredView = SettingsView(
            appState: unconfiguredApp,
            updateController: updateController,
            selectedTab: .service,
            initialShowPairingFlow: false
        )
        let unconfiguredHost = makeHostedSettingsView(unconfiguredView)
        let unconfiguredAll = findAccessibilityNodes(in: unconfiguredHost)
        let unconfiguredNodes = unconfiguredAll
            .filter { $0.identifier == AXID.Settings.Service.journalConnectionState }
        if !unconfiguredAll.isEmpty {
            #expect(unconfiguredNodes.count == 1)
            if !unconfiguredNodes.isEmpty {
                #expect(unconfiguredNodes[0].value == unconfiguredApp.tunnelLifecycleOwner.connectionVerdict.axToken)
            }
        }
        #expect(unconfiguredApp.tunnelLifecycleOwner.connectionVerdict.axToken == PairingConnectionAXState.unreachable.axToken)

        // 3. Mismatch
        let mismatchApp = AppState.forSnapshot(config: configuredConfig, initialTunnelPairing: pairing())
        mismatchApp.pendingSettingsTab = SettingsView.Tab.service.rawValue
        let mismatchView = SettingsView(
            appState: mismatchApp,
            updateController: updateController,
            selectedTab: .service,
            initialPairingMismatch: true
        )
        let mismatchHost = makeHostedSettingsView(mismatchView)
        let mismatchAll = findAccessibilityNodes(in: mismatchHost)
        let mismatchNodes = mismatchAll
            .filter { $0.identifier == AXID.Settings.Service.journalConnectionState }
        if !mismatchAll.isEmpty {
            #expect(mismatchNodes.count == 1)
            if !mismatchNodes.isEmpty {
                #expect(mismatchNodes[0].value == PairingConnectionAXState.mismatch.axToken)
            }
        }

        // 4. Nested re-link (initialShowPairingFlow + configured)
        let nestedApp = AppState.forSnapshot(config: configuredConfig, initialTunnelPairing: pairing())
        nestedApp.pendingSettingsTab = SettingsView.Tab.service.rawValue
        let nestedRelinkView = SettingsView(
            appState: nestedApp,
            updateController: updateController,
            selectedTab: .service,
            initialShowPairingFlow: true
        )
        let nestedRelinkHost = makeHostedSettingsView(nestedRelinkView)
        let nestedAll = findAccessibilityNodes(in: nestedRelinkHost)
        let nestedRelinkNodes = nestedAll
            .filter { $0.identifier == AXID.Settings.Service.journalConnectionState }
        if !nestedAll.isEmpty {
            #expect(nestedRelinkNodes.count == 1)
            if !nestedRelinkNodes.isEmpty {
                #expect(nestedRelinkNodes[0].value == configuredApp.tunnelLifecycleOwner.connectionVerdict.axToken)
            }
        }
    }

    @Test @MainActor func hostedSettingsViewRecoveryControlCounts() {
        let updateController = UpdateController(
            feedURL: nil,
            publicKey: nil,
            log: .setup,
            errorDomain: "app.solstone.observer.updates",
            defaults: .standard
        ) { _, _ in nil }

        let configuredConfig = AppConfig(
            serverURL: "https://example.com",
            serverKey: "secret",
            journalPath: NSTemporaryDirectory()
        )

        let allRecoveryIDs: Set<String> = [
            AXID.Settings.Service.pairingRetry,
            AXID.Settings.Service.pairingPaidPlanLink,
            AXID.Settings.Service.pairingMismatchFreshLink,
            AXID.Settings.Service.pairingMismatchSupport
        ]

        // 1. Configured: 0 recovery controls
        let configuredApp = AppState.forSnapshot(config: configuredConfig, initialTunnelPairing: pairing())
        let configuredView = SettingsView(appState: configuredApp, updateController: updateController, selectedTab: .service)
        let configuredHost = makeHostedSettingsView(configuredView)
        let configuredRecoveryNodes = findAccessibilityNodes(in: configuredHost)
            .filter { allRecoveryIDs.contains($0.identifier) }
        #expect(configuredRecoveryNodes.isEmpty)

        // 2. Mismatch: exactly 2 mismatch recovery controls (freshLink, support) and 0 retry/paidPlan
        let mismatchView = SettingsView(
            appState: configuredApp,
            updateController: updateController,
            selectedTab: .service,
            initialPairingMismatch: true
        )
        let mismatchHost = makeHostedSettingsView(mismatchView)
        let mismatchRecoveryNodes = findAccessibilityNodes(in: mismatchHost)
            .filter { allRecoveryIDs.contains($0.identifier) }
        if !mismatchRecoveryNodes.isEmpty {
            #expect(mismatchRecoveryNodes.count == 2)
            let mismatchIDs = Set(mismatchRecoveryNodes.map { $0.identifier })
            #expect(mismatchIDs.contains(AXID.Settings.Service.pairingMismatchFreshLink))
            #expect(mismatchIDs.contains(AXID.Settings.Service.pairingMismatchSupport))
            #expect(!mismatchIDs.contains(AXID.Settings.Service.pairingRetry))
            #expect(!mismatchIDs.contains(AXID.Settings.Service.pairingPaidPlanLink))
        }

        // 3. Nested re-link: no duplicate recovery controls
        let nestedRelinkView = SettingsView(
            appState: configuredApp,
            updateController: updateController,
            selectedTab: .service,
            initialShowPairingFlow: true
        )
        let nestedRelinkHost = makeHostedSettingsView(nestedRelinkView)
        let nestedRecoveryNodes = findAccessibilityNodes(in: nestedRelinkHost)
            .filter { allRecoveryIDs.contains($0.identifier) }
        let nestedIDCounts = Dictionary(grouping: nestedRecoveryNodes, by: { $0.identifier })
        for (_, nodes) in nestedIDCounts {
            #expect(nodes.count <= 1)
        }
    }

    @Test func singleJournalConnectionStateNodeInSettingsSource() throws {
        let settingsPath = "Sources/solstone/SettingsView.swift"
        let source = try String(contentsOfFile: settingsPath, encoding: .utf8)

        // 1. Ensure no companion overlay duplicates AXID.Settings.Service.journalConnectionState
        #expect(!source.contains("AXStateCompanion(id: AXID.Settings.Service.journalConnectionState"))

        // 2. Ensure each branch carries its own identifier attachment exactly once
        let targetIdentifier = ".accessibilityIdentifier(AXID.Settings.Service.journalConnectionState)"
        let occurrences = source.components(separatedBy: targetIdentifier).count - 1
        #expect(occurrences == 3)

        // 3. Ensure the 3 branches are in configuredJournalPanel, pairingMismatchPane, and pairingConnectionTruthRow
        let configuredSection = try extractSection(from: source, named: "configuredJournalPanel")
        #expect(configuredSection.contains(targetIdentifier))

        let mismatchSection = try extractSection(from: source, named: "pairingMismatchPane")
        #expect(mismatchSection.contains(targetIdentifier))

        let pairingTruthSection = try extractSection(from: source, named: "pairingConnectionTruthRow")
        #expect(pairingTruthSection.contains(targetIdentifier))
    }

    @Test @MainActor func openerRefusalAndSuccessIsolation() {
        final class OpenResultBox: @unchecked Sendable {
            var result = false
        }

        let appState = AppState.forSnapshot()
        var openedURLs: [URL] = []
        let box = OpenResultBox()
        let updateController = UpdateController(
            feedURL: nil,
            publicKey: nil,
            log: .setup,
            errorDomain: "app.solstone.observer.updates",
            defaults: .standard
        ) { _, _ in nil }

        let settings = SettingsView(
            appState: appState,
            updateController: updateController,
            openURL: { url in
                openedURLs.append(url)
                return box.result
            }
        )

        // Test entitlement opener failure
        box.result = false
        let entFailResult = settings.openEntitlementURL()
        #expect(!entFailResult)
        #expect(openedURLs.last?.absoluteString == "https://link.solstone.app")

        // Test entitlement opener success
        box.result = true
        let entSuccessResult = settings.openEntitlementURL()
        #expect(entSuccessResult)

        // Test support mailto failure
        box.result = false
        let supFailResult = settings.openSupportMailto()
        #expect(!supFailResult)
        #expect(openedURLs.last?.absoluteString == "mailto:support@solstone.app")

        // Test support mailto success
        box.result = true
        let supSuccessResult = settings.openSupportMailto()
        #expect(supSuccessResult)

        // Test isolation: openEntitlementURL success does not clear supportOpenFailed
        let supportFailedSettings = SettingsView(
            appState: appState,
            updateController: updateController,
            openURL: { _ in true },
            initialEntitlementOpenFailed: false,
            initialSupportOpenFailed: true
        )
        #expect(supportFailedSettings.supportOpenFailed)
        #expect(!supportFailedSettings.entitlementOpenFailed)
        let entSucceeded = supportFailedSettings.openEntitlementURL()
        #expect(entSucceeded)
        #expect(supportFailedSettings.supportOpenFailed)
        #expect(!supportFailedSettings.entitlementOpenFailed)

        // Test isolation: openSupportMailto success does not clear entitlementOpenFailed
        let entFailedSettings = SettingsView(
            appState: appState,
            updateController: updateController,
            openURL: { _ in true },
            initialEntitlementOpenFailed: true,
            initialSupportOpenFailed: false
        )
        #expect(entFailedSettings.entitlementOpenFailed)
        #expect(!entFailedSettings.supportOpenFailed)
        let supSucceeded = entFailedSettings.openSupportMailto()
        #expect(supSucceeded)
        #expect(entFailedSettings.entitlementOpenFailed)
        #expect(!entFailedSettings.supportOpenFailed)
    }
}

private func extractSection(from source: String, named sectionName: String) throws -> String {
    let pattern = "var\\s+\(sectionName):\\s*some\\s+View\\s*\\{"
    guard let range = source.range(of: pattern, options: .regularExpression) else {
        throw SectionExtractionError.sectionNotFound(sectionName)
    }
    let rest = source[range.lowerBound...]
    guard let endRange = rest.range(of: "\n    @ViewBuilder\n    private var ", options: []) ?? rest.range(of: "\n    // MARK:", options: []) else {
        return String(rest)
    }
    return String(rest[..<endRange.lowerBound])
}

private enum SectionExtractionError: Error {
    case sectionNotFound(String)
}

@MainActor
private func makeHostedSettingsView<V: View>(_ view: V) -> NSWindow {
    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.contentView = hostingView
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    hostingView.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

    if let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) {
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
    }

    return window
}

@MainActor
private func findAccessibilityNodes(in root: AnyObject) -> [(identifier: String, value: String?)] {
    var results: [(identifier: String, value: String?)] = []
    var visited = Set<ObjectIdentifier>()

    func walk(_ node: AnyObject) {
        let id = ObjectIdentifier(node)
        if visited.contains(id) { return }
        visited.insert(id)

        if let view = node as? NSView {
            let ident = view.accessibilityIdentifier()
            let val = view.accessibilityValue() as? String
            if !ident.isEmpty {
                results.append((identifier: ident, value: val))
            }
            if let children = view.accessibilityChildren() {
                for child in children {
                    walk(child as AnyObject)
                }
            }
            for subview in view.subviews {
                walk(subview)
            }
        } else if let elem = node as? NSAccessibilityElement {
            let ident = elem.accessibilityIdentifier()
            let val = elem.accessibilityValue() as? String
            if let ident, !ident.isEmpty {
                results.append((identifier: ident, value: val))
            }
            if let children = elem.accessibilityChildren() {
                for child in children {
                    walk(child as AnyObject)
                }
            }
        } else if let ax = node as? (any NSAccessibilityElementProtocol) {
            let ident = ax.accessibilityIdentifier?()
            if let ident, !ident.isEmpty {
                results.append((identifier: ident, value: nil))
            }
        }
    }

    if let win = root as? NSWindow {
        if let cv = win.contentView {
            walk(cv)
        }
        if let ch = win.accessibilityChildren() {
            for child in ch {
                walk(child as AnyObject)
            }
        }
        walk(root)
    }
    return results
}

