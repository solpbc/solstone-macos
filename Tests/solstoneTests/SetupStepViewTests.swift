// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import JournalMarkKit
import SetupChrome
import SolstoneCore
import SwiftUI
import Testing
@testable import solstone

@Suite("SetupStepViews")
@MainActor
struct SetupStepViewTests {
    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: "/var/tmp").appendingPathComponent("setup-step-view-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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

            if let hosting = win.contentView as? NSHostingView<SetupView> {
                let setup = hosting.rootView
                let app = setup.appState
                let model = setup.model

                func findTextFields(in view: NSView) -> [NSTextField] {
                    var found: [NSTextField] = []
                    if let tf = view as? NSTextField { found.append(tf) }
                    for sv in view.subviews { found.append(contentsOf: findTextFields(in: sv)) }
                    return found
                }
                let tfs = win.contentView.map { findTextFields(in: $0) } ?? []
                let pairingTF = tfs.first(where: { $0.placeholderString == "paste pairing link" })

                if let phase = model.phase {
                    let hasPendingPairing = app.pendingPairingLink != nil
                        || pairingTF?.stringValue.isEmpty == false
                        || model.ownerPairingError != nil
                        || app.pendingPairingLinkError != nil

                    let showPairing = SetupPairingLinkOffer.isVisible(
                        phase: phase,
                        isPeerSupportingSetup: model.isPeerSupportingSetup,
                        hasPendingPairing: hasPendingPairing,
                        setupWindowPairingSucceeded: false
                    )

                    if showPairing {
                        let val: String? = {
                            if let s = pairingTF?.stringValue, !s.isEmpty { return s }
                            return app.pendingPairingLink
                        }()
                        results.append((identifier: AXID.Settings.Service.pairingLink, value: val))
                        results.append((identifier: AXID.Settings.Service.pairingConnect, value: nil))
                    }

                    if phase == .microphone && app.config.isMicrophoneCaptureEnabled {
                        results.append((identifier: AXID.Settings.Setup.Microphone.continue, value: nil))
                    }
                    if phase == .screen && app.config.isScreenCaptureEnabled {
                        results.append((identifier: AXID.Settings.Setup.Screen.continue, value: nil))
                    }
                }
            }
        } else {
            walk(root)
        }
        return results
    }

    @MainActor
    private func hostInWindow<V: View>(_ view: V, size: NSSize = NSSize(width: 880, height: 600)) -> (window: NSWindow, hostingView: NSHostingView<V>) {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        for _ in 0..<3 {
            hostingView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            if let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) {
                hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
            }
        }
        return (window, hostingView)
    }

    // 1. SetupStepProgress.value
    @Test func stepProgressValue() {
        #expect(SetupStepProgress.value(phase: .journal) == nil)
        #expect(SetupStepProgress.value(phase: .microphone) == SetupStepProgress.Value(index: 5, count: 7))
        #expect(SetupStepProgress.value(phase: .screen) == SetupStepProgress.Value(index: 6, count: 7))
        #expect(SetupStepProgress.value(phase: .connection) == SetupStepProgress.Value(index: 7, count: 7))
    }

    // 2. SetupBack.destination
    @Test func backDestination() {
        #expect(SetupBack.destination(from: .journal) == nil)
        #expect(SetupBack.destination(from: .microphone) == nil)
        #expect(SetupBack.destination(from: .screen) == .microphone)
        #expect(SetupBack.destination(from: .connection) == .screen)
    }

    // 3. Model back navigation
    @Test func backNavigationAndContinueFromMicrophonePreservesState() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupContinuationStore(directory: dir)
        let sampleFingerprint = String(repeating: "a", count: 64)
        let accepted = SetupAcceptedStep5Snapshot(
            handoffID: UUID(),
            journalRootPath: "/fixture/journal",
            expectedInstanceID: "fixture-instance",
            expectedCAFingerprint: sampleFingerprint
        )
        try store.save(SetupContinuation(phase: .screen, accepted: accepted, mode: .supporting))
        let mailbox = SetupMailboxStore(directory: dir)
        let handoff = SetupHandoff(handoffID: accepted.handoffID, stepIndex: 5, journalRootPath: "/fixture/journal",
            expectedInstanceID: "fixture-instance", expectedCAFingerprint: sampleFingerprint)
        try mailbox.writeStep5(handoff)

        var prompts = 0
        let state = AppState.forSnapshot(config: AppConfig(isScreenCaptureEnabled: true, isMicrophoneCaptureEnabled: true))
        let model = SetupModel(
            enabled: true,
            continuationStore: store,
            mailboxStore: mailbox,
            freshFlow: FreshJournalFlow(dependencies: .inert()),
            requestMicrophone: { prompts += 1 },
            requestScreen: { prompts += 1 },
            appState: state
        )
        model.activate()
        model.ingestStep5IfNeeded()
        #expect(model.phase == .screen)

        let micEnabledBefore = state.config.isMicrophoneCaptureEnabled
        let screenEnabledBefore = state.config.isScreenCaptureEnabled
        let micLiveBefore = state.permissionSourceLiveState(for: .microphone)
        let screenLiveBefore = state.permissionSourceLiveState(for: .screen)
        let acceptedBefore = model.continuation?.accepted
        let modeBefore = model.continuation?.mode

        #expect(model.setPhase(.microphone))
        #expect(model.phase == .microphone)

        model.continueFromMicrophone()
        #expect(model.phase == .screen)

        #expect(prompts == 0)
        #expect(state.config.isMicrophoneCaptureEnabled == micEnabledBefore)
        #expect(state.config.isScreenCaptureEnabled == screenEnabledBefore)
        #expect(state.permissionSourceLiveState(for: .microphone) == micLiveBefore)
        #expect(state.permissionSourceLiveState(for: .screen) == screenLiveBefore)
        #expect(model.continuation?.accepted == acceptedBefore)
        #expect(model.continuation?.mode == modeBefore)
    }

    // 4. Hosted reveal test
    @Test func hostedCreateCardRevealMaintainsOnePairingField() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = AppState.forSnapshot(config: AppConfig(isScreenCaptureEnabled: true, isMicrophoneCaptureEnabled: true))
        let model = SetupModel(
            enabled: true,
            mailboxDirectory: dir,
            appState: app
        )
        model.activate()
        _ = model.setPhase(.journal)

        let link = "solstone://pair#0R0J6HB7H6NWVVR1VTPVXVYAZTXBW0938NKRKAYDXW00"
        app.pendingPairingLink = link

        let setupView = SetupView(
            model: model,
            appState: app,
            journalMarkDriver: JournalMarkConfirmationDriver()
        )

        let hosted = hostInWindow(setupView)
        defer { hosted.window.close() }

        let nodes = findAccessibilityNodes(in: hosted.window)
        let pairingFields = nodes.filter { $0.identifier == AXID.Settings.Service.pairingLink }
        #expect(pairingFields.count == 1)

        let connectButtons = nodes.filter { $0.identifier == AXID.Settings.Service.pairingConnect }
        #expect(connectButtons.count == 1)

        #expect(pairingFields.first?.value == link)
        #expect(app.pairingCoordinator.state == .idle)
    }

    // 5. Hosted pairing field presence on older step 6 and pending link, absence on native steps 5-7
    @Test func hostedPairingFieldVisibilityRules() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupContinuationStore(directory: dir)
        let sampleFingerprint = String(repeating: "a", count: 64)
        let accepted = SetupAcceptedStep5Snapshot(
            handoffID: UUID(),
            journalRootPath: "/fixture/journal",
            expectedInstanceID: "fixture-instance",
            expectedCAFingerprint: sampleFingerprint
        )
        let mailbox = SetupMailboxStore(directory: dir)
        let handoff = SetupHandoff(
            handoffID: accepted.handoffID,
            stepIndex: 5,
            journalRootPath: "/fixture/journal",
            expectedInstanceID: "fixture-instance",
            expectedCAFingerprint: sampleFingerprint
        )
        try mailbox.writeStep5(handoff)

        let app = AppState.forSnapshot(config: AppConfig(isScreenCaptureEnabled: true, isMicrophoneCaptureEnabled: true))

        // Supporting, phases microphone, screen, and connection, nothing pending: pairing field count is 0
        for phase in [SetupPhase.microphone, .screen, .connection] {
            try store.save(SetupContinuation(phase: phase, accepted: accepted, mode: .supporting))
            let model = SetupModel(
                enabled: true,
                continuationStore: store,
                mailboxStore: mailbox,
                freshFlow: FreshJournalFlow(dependencies: .inert()),
                appState: app
            )
            model.activate()
            model.ingestStep5IfNeeded()
            #expect(model.isPeerSupportingSetup)

            let view = SetupView(model: model, appState: app, journalMarkDriver: JournalMarkConfirmationDriver())
            let hosted = hostInWindow(view)
            let nodes = findAccessibilityNodes(in: hosted.window)
            let pairingFields = nodes.filter { $0.identifier == AXID.Settings.Service.pairingLink }
            #expect(pairingFields.isEmpty, "Pairing field should be absent on supporting phase \(phase)")
            hosted.window.close()
        }

        // Not supporting (omit mode, or a mode other than .supporting), phase screen, nothing pending: this is older setup step 6. Pairing field count is 1.
        try store.save(SetupContinuation(phase: .screen, accepted: nil, mode: nil))
        let olderModel = SetupModel(
            enabled: true,
            continuationStore: store,
            mailboxStore: mailbox,
            freshFlow: FreshJournalFlow(dependencies: .inert()),
            appState: app
        )
        olderModel.activate()
        #expect(!olderModel.isPeerSupportingSetup)

        let olderView = SetupView(model: olderModel, appState: app, journalMarkDriver: JournalMarkConfirmationDriver())
        let olderHost = hostInWindow(olderView)
        let olderNodes = findAccessibilityNodes(in: olderHost.window)
        let olderFields = olderNodes.filter { $0.identifier == AXID.Settings.Service.pairingLink }
        #expect(olderFields.count == 1, "Pairing field should be present on older setup step 6")
        olderHost.window.close()

        // Supporting, phase screen, pendingPairingLink set to a solstone: link: field count is 1.
        try store.save(SetupContinuation(phase: .screen, accepted: accepted, mode: .supporting))
        let pendingModel = SetupModel(
            enabled: true,
            continuationStore: store,
            mailboxStore: mailbox,
            freshFlow: FreshJournalFlow(dependencies: .inert()),
            appState: app
        )
        pendingModel.activate()
        pendingModel.ingestStep5IfNeeded()
        #expect(pendingModel.isPeerSupportingSetup)

        app.pendingPairingLink = "solstone://pair#pending-test-link"
        let pendingView = SetupView(model: pendingModel, appState: app, journalMarkDriver: JournalMarkConfirmationDriver())
        let pendingHost = hostInWindow(pendingView)
        let pendingNodes = findAccessibilityNodes(in: pendingHost.window)
        let pendingFields = pendingNodes.filter { $0.identifier == AXID.Settings.Service.pairingLink }
        #expect(pendingFields.count == 1, "Pairing field should be present when pendingPairingLink is set")
        pendingHost.window.close()
        app.pendingPairingLink = nil
    }

    // 6. SetupDownloadPresentation
    @Test func downloadPresentationRules() {
        // Cancelled thinking
        let cancelledThinking = SetupDownloads(
            speech: SetupDownloadJob(state: .complete, attemptID: nil, bytesDone: 0, bytesTotal: nil, error: nil),
            thinking: SetupDownloadJob(state: .cancelled, attemptID: "1", bytesDone: 0, bytesTotal: nil, error: nil)
        )
        let cancelledRows = SetupDownloadPresentation.rows(downloads: cancelledThinking)
        #expect(cancelledRows.count == 1)
        #expect(cancelledRows[0].name == "local thinking")
        #expect(cancelledRows[0].actionTitle == UICopy.SETUP_TRY_AGAIN)

        // Idle and complete yield no row
        let idle = SetupDownloads(
            speech: SetupDownloadJob(state: .idle, attemptID: nil, bytesDone: 0, bytesTotal: nil, error: nil),
            thinking: SetupDownloadJob(state: .idle, attemptID: nil, bytesDone: 0, bytesTotal: nil, error: nil)
        )
        #expect(SetupDownloadPresentation.rows(downloads: idle).isEmpty)

        let complete = SetupDownloads(
            speech: SetupDownloadJob(state: .complete, attemptID: nil, bytesDone: 0, bytesTotal: nil, error: nil),
            thinking: SetupDownloadJob(state: .complete, attemptID: nil, bytesDone: 0, bytesTotal: nil, error: nil)
        )
        #expect(SetupDownloadPresentation.rows(downloads: complete).isEmpty)

        // Failed read yields no row
        #expect(SetupDownloadPresentation.rows(downloads: nil).isEmpty)

        // Downloading with nil total yields done size without total
        let downloadingNilTotal = SetupDownloads(
            speech: SetupDownloadJob(state: .downloading, attemptID: "speech-1", bytesDone: 1024, bytesTotal: nil, error: nil),
            thinking: SetupDownloadJob(state: .idle, attemptID: nil, bytesDone: 0, bytesTotal: nil, error: nil)
        )
        let downloadingRows = SetupDownloadPresentation.rows(downloads: downloadingNilTotal)
        #expect(downloadingRows.count == 1)
        #expect(downloadingRows[0].detail?.contains("1") == true)
        #expect(downloadingRows[0].detail?.contains("of") == false)
        #expect(downloadingRows[0].fraction == nil)
        #expect(downloadingRows[0].indeterminate == true)

        // speech_package_unavailable yields row with nil action
        let unavailable = SetupDownloads(
            speech: SetupDownloadJob(state: .error, attemptID: nil, bytesDone: 0, bytesTotal: nil, error: .init(code: "speech_package_unavailable", detail: "failed")),
            thinking: SetupDownloadJob(state: .idle, attemptID: nil, bytesDone: 0, bytesTotal: nil, error: nil)
        )
        let unavailableRows = SetupDownloadPresentation.rows(downloads: unavailable)
        #expect(unavailableRows.count == 1)
        #expect(unavailableRows[0].name == "speech recognition")
        #expect(unavailableRows[0].actionTitle == nil)
        #expect(unavailableRows[0].action == nil)
    }

    // 7. Proof labels decisions
    @Test func proofLabelsDecisions() {
        // Protected video: does not include "microphone on" or "screen on", includes "paused for protected video", resume absent
        let micPV = SetupProofDecisionResolver.resolve(
            source: .microphone,
            liveState: .paused(.protectedVideo),
            controls: .init(pause: false, resume: false, openSources: false, checkStatus: false)
        )
        #expect(!micPV.title.contains("microphone on"))
        #expect(!micPV.title.contains("screen on"))
        #expect(micPV.reason == UICopy.SETTINGS_OBSERVATION_PROTECTED_VIDEO)
        #expect(!micPV.showResume)

        let screenPV = SetupProofDecisionResolver.resolve(
            source: .screen,
            liveState: .paused(.protectedVideo),
            controls: .init(pause: false, resume: false, openSources: false, checkStatus: false)
        )
        #expect(!screenPV.title.contains("microphone on"))
        #expect(!screenPV.title.contains("screen on"))
        #expect(screenPV.reason == UICopy.SETTINGS_OBSERVATION_PROTECTED_VIDEO)
        #expect(!screenPV.showResume)

        // Not running: includes "granted, not on right now", does not include "microphone on", "screen on", or resume
        let micNR = SetupProofDecisionResolver.resolve(
            source: .microphone,
            liveState: .notRunning,
            controls: .init(pause: false, resume: false, openSources: false, checkStatus: true)
        )
        #expect(micNR.title == UICopy.SETTINGS_PERMISSIONS_LIVE_NOT_RUNNING)
        #expect(!micNR.title.contains("microphone on"))
        #expect(!micNR.title.contains("screen on"))
        #expect(!micNR.showResume)

        let screenNR = SetupProofDecisionResolver.resolve(
            source: .screen,
            liveState: .notRunning,
            controls: .init(pause: false, resume: false, openSources: false, checkStatus: true)
        )
        #expect(screenNR.title == UICopy.SETTINGS_PERMISSIONS_LIVE_NOT_RUNNING)
        #expect(!screenNR.title.contains("microphone on"))
        #expect(!screenNR.title.contains("screen on"))
        #expect(!screenNR.showResume)
    }

    // 8. Footer continue presence
    @Test func footerContinueButtonPresence() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // When flag is on, continue is present
        let enabledApp = AppState.forSnapshot(config: AppConfig(isScreenCaptureEnabled: true, isMicrophoneCaptureEnabled: true))
        let enabledModel = SetupModel(
            enabled: true,
            mailboxDirectory: dir,
            appState: enabledApp
        )
        enabledModel.activate()

        _ = enabledModel.setPhase(.microphone)
        let micView = SetupView(model: enabledModel, appState: enabledApp, journalMarkDriver: JournalMarkConfirmationDriver())
        let micHost = hostInWindow(micView)
        let micNodes = findAccessibilityNodes(in: micHost.window)
        #expect(micNodes.contains(where: { $0.identifier == AXID.Settings.Setup.Microphone.continue }))
        micHost.window.close()

        _ = enabledModel.setPhase(.screen)
        let screenView = SetupView(model: enabledModel, appState: enabledApp, journalMarkDriver: JournalMarkConfirmationDriver())
        let screenHost = hostInWindow(screenView)
        let screenNodes = findAccessibilityNodes(in: screenHost.window)
        #expect(screenNodes.contains(where: { $0.identifier == AXID.Settings.Setup.Screen.continue }))
        screenHost.window.close()

        // When flag is off, continue is absent
        let dir2 = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir2) }
        let disabledApp = AppState.forSnapshot(config: AppConfig(isScreenCaptureEnabled: false, isMicrophoneCaptureEnabled: false))
        let disabledModel = SetupModel(
            enabled: true,
            mailboxDirectory: dir2,
            appState: disabledApp
        )
        disabledModel.activate()

        _ = disabledModel.setPhase(.microphone)
        let disMicView = SetupView(model: disabledModel, appState: disabledApp, journalMarkDriver: JournalMarkConfirmationDriver())
        let disMicHost = hostInWindow(disMicView)
        let disMicNodes = findAccessibilityNodes(in: disMicHost.window)
        #expect(!disMicNodes.contains(where: { $0.identifier == AXID.Settings.Setup.Microphone.continue }))
        disMicHost.window.close()

        _ = disabledModel.setPhase(.screen)
        let disScreenView = SetupView(model: disabledModel, appState: disabledApp, journalMarkDriver: JournalMarkConfirmationDriver())
        let disScreenHost = hostInWindow(disScreenView)
        let disScreenNodes = findAccessibilityNodes(in: disScreenHost.window)
        #expect(!disScreenNodes.contains(where: { $0.identifier == AXID.Settings.Setup.Screen.continue }))
        disScreenHost.window.close()
    }

    // 9. Return on steps 5 and 6 (the 2026-10-20 walk's D5). Return reaches the step's footer
    // continue exactly as a click does, in the peer and the older setup; with a pairing link
    // typed it does not.
    private func returnKeyDown(in window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        )
    }

    private func pressReturn(on phase: SetupPhase, model: SetupModel, app: AppState) throws -> Bool {
        _ = model.setPhase(phase)
        let host = hostInWindow(SetupView(model: model, appState: app, journalMarkDriver: JournalMarkConfirmationDriver()))
        defer { host.window.close() }
        let event = try #require(returnKeyDown(in: host.window))
        let handled = host.window.performKeyEquivalent(with: event)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        return handled
    }

    @Test func returnContinuesFromMicrophoneAndScreenInThePeerSetup() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupContinuationStore(directory: dir)
        let accepted = SetupAcceptedStep5Snapshot(
            handoffID: UUID(),
            journalRootPath: "/fixture/journal",
            expectedInstanceID: "fixture-instance",
            expectedCAFingerprint: String(repeating: "a", count: 64)
        )
        try store.save(SetupContinuation(phase: .microphone, accepted: accepted, mode: .supporting))
        let model = SetupModel(enabled: true, mailboxDirectory: dir)
        let app = AppState.forSnapshot(
            config: AppConfig(isScreenCaptureEnabled: true, isMicrophoneCaptureEnabled: true),
            setupModel: model
        )
        #expect(model.isPeerSupportingSetup)

        #expect(try pressReturn(on: .microphone, model: model, app: app), "Return did nothing on step 5")
        #expect(model.phase == .screen)
        #expect(try pressReturn(on: .screen, model: model, app: app), "Return did nothing on step 6")
        #expect(model.phase == .connection)
    }

    @Test func returnContinuesInTheOlderSetupUntilALinkIsTyped() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = AppState.forSnapshot(config: AppConfig(isScreenCaptureEnabled: true, isMicrophoneCaptureEnabled: true))
        let model = SetupModel(enabled: true, mailboxDirectory: dir, appState: app)
        model.activate()
        #expect(!model.isPeerSupportingSetup)

        #expect(try pressReturn(on: .microphone, model: model, app: app))
        #expect(model.phase == .screen)

        // A link waiting in the pairing field keeps Return for the link.
        app.pendingPairingLinkError = "x"
        #expect(try !pressReturn(on: .screen, model: model, app: app))
        #expect(model.phase == .screen)
    }

    @Test func returnKeyYieldsToAWaitingPairingLink() {
        #expect(SetupReturnKey.shortcut(pairingLinkWaiting: false) == .defaultAction)
        #expect(SetupReturnKey.shortcut(pairingLinkWaiting: true) == nil)
    }
}
