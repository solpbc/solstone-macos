// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import JournalMarkKit
import Sparkle
import SwiftUI

@MainActor
final class JournalAppModel {
    static var shared: JournalAppModel?

    let config: JournalAppConfig
    let supervisor: JournalSupervisor
    private let updaterController: SPUStandardUpdaterController
    private var startupTask: Task<Void, Never>?
    private(set) var terminationPrepared = false

    init(
        config: JournalAppConfig = JournalAppConfig(),
        supervisor: JournalSupervisor = JournalSupervisor()
    ) {
        self.config = config
        self.supervisor = supervisor
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func launch() {
        JournalMarkFont.register()
        config.applyLaunchAtLoginPreference()
        let root = config.resolvedJournalRoot
        startupTask = Task { @MainActor [supervisor] in
            _ = await supervisor.start(journalRoot: root)
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
        WindowGroup("journal") {
            VStack(spacing: 12) {
                Text("journal")
                    .font(.title)
                Text("running locally")
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 360, minHeight: 220)
        }
    }
}
