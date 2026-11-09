// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

/// Terminal as one of this app's sources. While it is on and the app isn't paused,
/// the bundled helper takes in the owner's tmux sessions; this app delivers what it
/// writes over its own pairing. The screen being locked or another user in front
/// doesn't stop it: only pause, turning it off and quitting do.
@MainActor
@Observable
final class TerminalSource {
    enum State: Equatable {
        case off
        case paused
        case tmuxNotFound
        case oldAppInstalled
        case running
        case restarting
    }

    private(set) var state: State = .off

    @ObservationIgnored private let helperURL: URL
    @ObservationIgnored private let spool: URL
    @ObservationIgnored private let planner: TerminalUploadPlanner
    @ObservationIgnored private let isEnabled: () -> Bool
    @ObservationIgnored private let isPaused: () -> Bool
    @ObservationIgnored private let oldAppInstalled: @Sendable () -> Bool
    @ObservationIgnored private let locateTmux: @Sendable () -> String?
    @ObservationIgnored private var probing = false
    @ObservationIgnored private var process: TerminalHelperProcess?
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var cadence: Task<Void, Never>?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var shuttingDown = false
    @ObservationIgnored private var generation = 0

    private static let stopWait: Duration = .seconds(12)
    private static let planInterval: Duration = .seconds(60)

    init(
        helperURL: URL,
        spool: URL,
        planner: TerminalUploadPlanner,
        isEnabled: @escaping () -> Bool,
        isPaused: @escaping () -> Bool,
        oldAppInstalled: @escaping @Sendable () -> Bool = { TerminalLegacyInstall.isPresent() },
        locateTmux: @escaping @Sendable () -> String? = { TerminalTmuxLocator.locate() }
    ) {
        self.helperURL = helperURL
        self.spool = spool
        self.planner = planner
        self.isEnabled = isEnabled
        self.isPaused = isPaused
        self.oldAppInstalled = oldAppInstalled
        self.locateTmux = locateTmux
    }

    func start() {
        cadence = Task { [weak self] in
            while !Task.isCancelled {
                await self?.planner.planAndUpload()
                try? await Task.sleep(for: Self.planInterval)
            }
        }
        reconcile()
    }

    /// Brings the helper in line with the owner's settings.
    func reconcile() {
        guard !shuttingDown else { return }
        restartTask?.cancel()
        restartTask = nil
        guard isEnabled() else {
            stopHelper()
            state = .off
            return
        }
        guard !isPaused() else {
            stopHelper()
            state = .paused
            return
        }
        guard process == nil, !probing else { return }
        // A login shell can take seconds to answer, so this stays off the main actor.
        probing = true
        let oldAppInstalled = oldAppInstalled
        let locateTmux = locateTmux
        Task { [weak self] in
            let (installed, tmux) = await Task.detached { () -> (Bool, String?) in
                let installed = oldAppInstalled()
                return (installed, installed ? nil : locateTmux())
            }.value
            self?.finishProbe(oldAppInstalled: installed, tmux: tmux)
        }
    }

    private func finishProbe(oldAppInstalled installed: Bool, tmux: String?) {
        probing = false
        guard !shuttingDown, isEnabled(), !isPaused(), process == nil else { return }
        guard !installed else {
            state = .oldAppInstalled
            return
        }
        guard let tmux else {
            state = .tmuxNotFound
            scheduleRestart()
            return
        }
        startHelper(tmux: tmux)
    }

    private func startHelper(tmux: String) {
        do {
            try TerminalSpool.ensureRoot(spool)
            generation += 1
            let run = generation
            let helper = TerminalHelperProcess(
                helper: helperURL,
                spool: spool,
                tmux: tmux,
                onEvent: { [weak self] event in
                    Task { @MainActor in self?.handle(event, run: run) }
                },
                onExit: { [weak self] status in
                    Task { @MainActor in self?.helperExited(status: status, run: run) }
                }
            )
            try helper.start()
            process = helper
            state = .running
            Task { await planner.planAndUpload() }
        } catch {
            Logger.general.error("Terminal helper did not start: \(error.localizedDescription, privacy: .public)")
            state = .restarting
            scheduleRestart()
        }
    }

    private func handle(_ event: TerminalHelperEvent, run: Int) {
        guard run == generation else { return }
        switch event {
        case .ready:
            failures = 0
        case .segment:
            Task { await planner.planAndUpload() }
        case .tmuxHealth(let found):
            state = found ? .running : .tmuxNotFound
        case .stopped:
            break
        }
    }

    private func helperExited(status: Int32, run: Int) {
        guard run == generation else { return }
        process = nil
        Task { await planner.planAndUpload() }
        guard !shuttingDown, isEnabled(), !isPaused() else { return }
        Logger.general.error("Terminal helper exited with status \(status, privacy: .public)")
        failures += 1
        state = .restarting
        scheduleRestart()
    }

    private func scheduleRestart() {
        let delay = min(60, 2 << min(failures, 5))
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.reconcile()
        }
    }

    private func stopHelper() {
        guard let helper = process else { return }
        process = nil
        generation += 1
        helper.sendStop()
        Task {
            try? await Task.sleep(for: Self.stopWait)
            helper.kill()
        }
    }

    func setUploading(_ working: Bool) {
        process?.sendSync(working: working)
    }

    /// Lets the open segment finish and the owner's tmux options come back.
    func shutdown() async {
        shuttingDown = true
        cadence?.cancel()
        restartTask?.cancel()
        guard let helper = process else { return }
        helper.sendStop()
        let deadline = ContinuousClock.now + Self.stopWait
        while process != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process != nil { helper.kill() }
    }
}
