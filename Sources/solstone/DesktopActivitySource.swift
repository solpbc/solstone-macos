// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Foundation
import Observation
import os

@MainActor @Observable
final class DesktopActivitySource {
    private(set) var enabled = false
    private(set) var paused = true
    private(set) var failed = false
    private(set) var titleUnavailable = false
    private(set) var urlUnavailable = false
    private var settings = DesktopActivitySettings(AppConfig())
    private let store: DesktopActivityStore
    private let eligibility: @MainActor () -> Bool
    private let locked: @MainActor () -> Bool
    private let captureOpen: @MainActor () -> Bool
    private let foreground: @MainActor () -> DesktopActivityApp?
    private let reader: @Sendable (DesktopActivityApp, DesktopActivitySettings, DesktopActivityReadPermit) -> DesktopActivityObservation
    private let now: @MainActor () -> Date
    private let onSealed: @MainActor () -> Void
    private var generation: UInt64 = 0
    private var notifiedPublication = 0
    private var worker: Task<Void, Never>?
    private var readPermit: DesktopActivityReadPermit?
    @ObservationIgnored nonisolated(unsafe) private var timer: Timer?
    @ObservationIgnored nonisolated(unsafe) private var activation: NSObjectProtocol?

    var statusText: String {
        if failed { return "activity couldn't be saved. check free space on this mac." }
        return !enabled ? "activity is off" : (paused ? "activity is paused" : "activity is on")
    }

    init(storage: StorageManager,
         eligibility: @escaping @MainActor () -> Bool,
         locked: @escaping @MainActor () -> Bool,
         captureOpen: @escaping @MainActor () -> Bool = { false },
         foreground: @escaping @MainActor () -> DesktopActivityApp? = DesktopActivityApp.frontmost,
         reader: @escaping @Sendable (DesktopActivityApp, DesktopActivitySettings, DesktopActivityReadPermit) -> DesktopActivityObservation = { DesktopActivityReader(permit: $2).read(app: $0, settings: $1) },
         now: @escaping @MainActor () -> Date = Date.init,
         onSealed: @escaping @MainActor () -> Void = {}) {
        store = DesktopActivityStore(storage: storage)
        self.eligibility = eligibility; self.locked = locked; self.captureOpen = captureOpen; self.foreground = foreground
        self.reader = reader; self.now = now; self.onSealed = onSealed
    }

    func start(config: AppConfig) {
        do { try store.recover(); notifyPublication() } catch { fail() }
        configure(config)
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.invalidate(); self?.sample() }
        }
    }

    deinit {
        timer?.invalidate()
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
    }

    func configure(_ config: AppConfig) {
        let next = DesktopActivitySettings(config)
        guard next != settings || enabled != next.enabled else { return }
        invalidate()
        settings = next; enabled = next.enabled
        // A new explicit setting action can retry failed storage, preserving its old checkpoint.
        if failed {
            do { try store.recover(); failed = false } catch { fail(); return }
        }
        sample()
    }

    /// Called synchronously at owner and lifecycle boundaries, before asynchronous media teardown.
    func invalidate() {
        generation &+= 1
        readPermit?.revoke()
        worker?.cancel()
        // A cancelled detached read is still bounded; do not start a second one until it returns.
        do {
            if failed { try store.seal() } else { try store.end(at: milliseconds, captureOpen: captureOpen()) }
            notifyPublication()
        } catch { fail() }
        paused = !eligibility()
    }

    /// Called as a capture segment's capture ends, before it is finished: its activity goes in it.
    func placeInCaptureSegment(_ directory: URL) {
        guard !failed else { return }
        do { try store.place(into: directory, at: milliseconds) } catch { fail() }
    }

    func stop() {
        invalidate()
        timer?.invalidate(); timer = nil
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation); self.activation = nil }
    }

    private var milliseconds: Int64 { Int64((now().timeIntervalSince1970 * 1000).rounded()) }

    @discardableResult func sample() -> Task<Void, Never>? {
        paused = !eligibility()
        guard enabled, !failed else { return nil }
        if paused {
            // Lock is a lifecycle observation, with no foreground facts. Owner pause wins.
            if locked() {
                do { try store.observe([DesktopActivityRow(kind: "activity", method: "nsworkspace", state: "locked")], at: milliseconds, captureOpen: captureOpen()) }
                catch { fail() }
            }
            return nil
        }
        guard worker == nil else { return worker }
        guard let app = foreground(), !settings.excludes(app) else {
            do { try store.end(at: milliseconds, captureOpen: captureOpen()); notifyPublication() } catch { fail() }
            return nil
        }
        let revision = generation, selected = settings, read = reader
        let permit = DesktopActivityReadPermit()
        readPermit = permit
        worker = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { read(app, selected, permit) }.value
            guard let self else { return }
            self.worker = nil
            guard revision == self.generation, self.enabled, !self.failed,
                  self.eligibility(), self.foreground() == app, self.settings == selected else { return }
            if let windowID = result.windowID,
               DesktopActivityReader.frontWindowID(pid: app.pid) != windowID { return }
            do {
                try self.store.observe(result.rows, at: self.milliseconds, captureOpen: self.captureOpen())
                self.titleUnavailable = result.titleUnavailable
                self.urlUnavailable = result.urlUnavailable
                self.notifyPublication()
            } catch { self.fail() }
        }
        return worker
    }

    private func notifyPublication() {
        if store.publicationCount != notifiedPublication {
            notifiedPublication = store.publicationCount
            onSealed()
        }
    }

    private func fail() {
        failed = true
        readPermit?.revoke()
        generation &+= 1
        Logger.storage.error("Desktop activity storage is unavailable")
    }
}
