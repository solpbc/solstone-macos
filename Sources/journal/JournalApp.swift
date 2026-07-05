// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import JournalMarkKit
import os
import Sparkle
import SwiftUI

@MainActor
final class JournalAppModel {
    static var shared: JournalAppModel?

    let config: JournalAppConfig
    let supervisor: JournalSupervisor
    let windowModel: JournalWindowModel
    private let updaterController: SPUStandardUpdaterController
    private var startupTask: Task<Void, Never>?
    private(set) var terminationPrepared = false

    init(
        config: JournalAppConfig = JournalAppConfig(),
        supervisor: JournalSupervisor = JournalSupervisor(),
        startsUpdater: Bool = true
    ) {
        self.config = config
        self.supervisor = supervisor
        self.windowModel = JournalWindowModel(config: config, supervisor: supervisor)
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: startsUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func launch() {
        JournalMarkFont.register()
        config.applyLaunchAtLoginPreference()
        windowModel.prepareForWindowOpen()
        guard let root = config.journalRoot else {
            return
        }
        startupTask = Task { @MainActor [supervisor, windowModel] in
            _ = await supervisor.start(journalRoot: root)
            await windowModel.loadForWindowOpen()
        }
    }

    func prepareWindowOpen(load: Bool = true) {
        windowModel.prepareForWindowOpen()
        if load {
            Task { @MainActor [windowModel] in
                await windowModel.loadForWindowOpen()
            }
        }
    }

    func prepareForTermination() async {
        guard !terminationPrepared else { return }
        terminationPrepared = true
        startupTask?.cancel()
        await supervisor.terminate(reason: "ordinary-quit")
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
            JournalWindowSceneRoot(model: model.windowModel)
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
    }
}

private struct JournalWindowSceneRoot: View {
    let model: JournalWindowModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        JournalSettingsWindow(model: model)
            .task {
                await model.loadForWindowOpen()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openJournalWindow)) { _ in
                model.prepareForWindowOpen()
                openWindow(id: "journal")
                NSApp.activate(ignoringOtherApps: true)
                Task {
                    await model.loadForWindowOpen()
                }
            }
    }
}

private extension Notification.Name {
    static let openJournalWindow = Notification.Name("openJournalWindow")
}
