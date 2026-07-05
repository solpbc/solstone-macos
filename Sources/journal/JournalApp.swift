// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import JournalMarkKit
import os
import SwiftUI
import UpdateKit

@MainActor
final class JournalAppModel {
    static var shared: JournalAppModel?

    let config: JournalAppConfig
    let supervisor: JournalSupervisor
    let windowModel: JournalWindowModel
    let firstRunModel: JournalFirstRunModel
    private var startupTask: Task<Void, Never>?
    private(set) var terminationPrepared = false
    private(set) var appKitTerminationBegan = false

    lazy var updateController: UpdateController = makeUpdateController()

    init(
        config: JournalAppConfig = JournalAppConfig(),
        supervisor: JournalSupervisor = JournalSupervisor()
    ) {
        self.config = config
        self.supervisor = supervisor
        let windowModel = JournalWindowModel(config: config, supervisor: supervisor)
        self.windowModel = windowModel
        self.firstRunModel = JournalFirstRunModel(
            config: config,
            startSupervisor: { [supervisor] root in
                await supervisor.start(journalRoot: root)
            },
            windowModel: windowModel
        )
    }

    func launch() {
        JournalMarkFont.register()
        config.applyLaunchAtLoginPreference()
        windowModel.prepareForWindowOpen()
        startupTask = Task { @MainActor [firstRunModel] in
            await firstRunModel.decideLaunchRoute()
        }
    }

    func prepareWindowOpen(load: Bool = true) {
        windowModel.prepareForWindowOpen()
        if load, firstRunModel.route == .home {
            Task { @MainActor [windowModel] in
                await windowModel.loadForWindowOpen()
            }
        }
    }

    func prepareForTermination() async {
        noteAppKitTerminationBegan()
        guard !terminationPrepared else { return }
        terminationPrepared = true
        startupTask?.cancel()
        await supervisor.terminate(reason: "ordinary-quit")
    }

    func noteAppKitTerminationBegan() {
        appKitTerminationBegan = true
    }

    func resetAfterFailedUpdaterInstall() {
        terminationPrepared = false
        appKitTerminationBegan = false
    }

    func reestablishSupervisionAfterFailedUpdate() async {
        guard let root = config.journalRoot else { return }
        _ = await supervisor.start(journalRoot: root)
    }

    private func makeUpdateController() -> UpdateController {
        UpdateController(
            log: Logger.updates,
            errorDomain: "app.solstone.journal.updates",
            exclusivity: { [weak supervisor] in
                guard let supervisor else { return false }
                switch supervisor.state {
                case .materializing, .starting, .waitingForReadiness:
                    return true
                default:
                    return false
                }
            },
            preInstallFinalizer: { [weak supervisor] in
                await supervisor?.terminate(reason: "updater-install")
            },
            installFailureRecovery: { [weak self] in
                self?.resetAfterFailedUpdaterInstall()
                await self?.reestablishSupervisionAfterFailedUpdate()
            },
            terminationBegan: { [weak self] in
                self?.appKitTerminationBegan ?? false
            }
        )
    }
}

@MainActor
final class JournalAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        JournalAppModel.shared?.launch()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let model = JournalAppModel.shared else {
            Logger.journalApp.error("JournalAppModel.shared nil in applicationShouldHandleReopen")
            return true
        }
        if let journalWindow = NSApp.windows.first(where: {
            $0.identifier?.rawValue.contains("journal") == true || $0.title == "journal"
        }) {
            model.prepareWindowOpen()
            journalWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            model.prepareWindowOpen(load: false)
            Logger.journalApp.info("applicationShouldHandleReopen: no journal NSWindow found; posting open journal notification")
            NotificationCenter.default.post(name: .openJournalWindow, object: nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = JournalAppModel.shared else {
            return .terminateNow
        }
        model.noteAppKitTerminationBegan()
        if model.terminationPrepared {
            return .terminateNow
        }
        Task { @MainActor in
            await model.prepareForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct JournalApp: App {
    @NSApplicationDelegateAdaptor(JournalAppDelegate.self) private var appDelegate
    @State private var model: JournalAppModel

    init() {
        let model = JournalAppModel()
        JournalAppModel.shared = model
        _model = State(initialValue: model)
    }

    var body: some Scene {
        Window("journal", id: "journal") {
            JournalWindowSceneRoot(
                model: model.windowModel,
                firstRunModel: model.firstRunModel,
                updateController: model.updateController
            )
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
    }
}

private struct JournalWindowSceneRoot: View {
    let model: JournalWindowModel
    @Bindable var firstRunModel: JournalFirstRunModel
    @Bindable var updateController: UpdateController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if firstRunModel.route == .home {
                ZStack(alignment: .top) {
                    JournalSettingsWindow(model: model, updateController: updateController)
                        .task {
                            await model.loadForWindowOpen()
                        }

                    if firstRunModel.adoptMessage == JournalFirstRunCopy.adoptLandingLine {
                        Text(JournalFirstRunCopy.adoptLandingLine)
                            .font(.callout)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .padding(.top, 12)
                    }
                }
            } else {
                JournalFirstRunView(model: firstRunModel)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openJournalWindow)) { _ in
            model.prepareForWindowOpen()
            openWindow(id: "journal")
            NSApp.activate(ignoringOtherApps: true)
            if firstRunModel.route == .home {
                Task {
                    await model.loadForWindowOpen()
                }
            }
        }
    }
}

private extension Notification.Name {
    static let openJournalWindow = Notification.Name("openJournalWindow")
}
