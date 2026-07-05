// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Darwin
import Foundation
import JournalMarkKit
import os

@MainActor
protocol JournalIconApplying {
    func apply(_ image: NSImage, toBundleAt path: String) -> Bool
    func clearCustomIcon(atBundleAt path: String) -> Bool
    func setDockImage(_ image: NSImage?)
}

@MainActor
struct NSWorkspaceIconApplier: JournalIconApplying {
    func apply(_ image: NSImage, toBundleAt path: String) -> Bool {
        NSWorkspace.shared.setIcon(image, forFile: path, options: [])
    }

    func clearCustomIcon(atBundleAt path: String) -> Bool {
        NSWorkspace.shared.setIcon(nil, forFile: path, options: [])
    }

    func setDockImage(_ image: NSImage?) {
        NSApp.applicationIconImage = image
    }
}

@MainActor
protocol JournalBundleIconInspecting {
    func hasCustomIcon(atBundleAt path: String) -> Bool
}

@MainActor
struct FinderInfoBundleIconInspector: JournalBundleIconInspecting {
    func hasCustomIcon(atBundleAt path: String) -> Bool {
        let iconFile = URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent("Icon\r")
        guard FileManager.default.fileExists(atPath: iconFile.path) else {
            return false
        }

        var finderInfo = [UInt8](repeating: 0, count: 32)
        let bytesRead = path.withCString { filePath in
            XATTR_FINDERINFO_NAME.withCString { attributeName in
                finderInfo.withUnsafeMutableBytes { buffer in
                    getxattr(filePath, attributeName, buffer.baseAddress, buffer.count, 0, 0)
                }
            }
        }
        guard bytesRead >= 10 else {
            return false
        }

        let flags = UInt16(finderInfo[8]) << 8 | UInt16(finderInfo[9])
        return flags & 0x0400 != 0
    }
}

@MainActor
protocol JournalIconLogging {
    func notice(_ message: String)
}

@MainActor
struct JournalLoggerIconLog: JournalIconLogging {
    func notice(_ message: String) {
        Logger.journalApp.notice("\(message, privacy: .public)")
    }
}

@MainActor
final class JournalIconManager {
    private enum Work: Sendable {
        case owner(JournalMark)
        case reassert
    }

    private let config: JournalAppConfig
    private let applier: any JournalIconApplying
    private let inspector: any JournalBundleIconInspecting
    private let logger: any JournalIconLogging
    private let bundlePath: String
    private let notificationCenter: NotificationCenter
    private var notificationObserver: NSObjectProtocol?
    private var inFlight: Task<Void, Never>?

    init(
        config: JournalAppConfig,
        applier: any JournalIconApplying = NSWorkspaceIconApplier(),
        inspector: any JournalBundleIconInspecting = FinderInfoBundleIconInspector(),
        logger: any JournalIconLogging = JournalLoggerIconLog(),
        bundlePath: String = Bundle.main.bundlePath,
        notificationCenter: NotificationCenter = .default
    ) {
        self.config = config
        self.applier = applier
        self.inspector = inspector
        self.logger = logger
        self.bundlePath = bundlePath
        self.notificationCenter = notificationCenter
    }

    func start() {
        if notificationObserver == nil {
            notificationObserver = notificationCenter.addObserver(
                forName: .journalMarkLocked,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let mark = JournalMarkLockedNotification.mark(from: notification) else {
                    return
                }
                Task { @MainActor [weak self] in
                    self?.enqueue(.owner(mark))
                }
            }
        }
        reassertOnLaunch()
    }

    func reassertOnLaunch() {
        enqueue(.reassert)
    }

    func handleIdentityMark(_ mark: JournalMark) {
        guard config.cachedIconMark() == nil else { return }
        enqueue(.owner(mark))
    }

    private func enqueue(_ work: Work) {
        guard inFlight == nil else { return }
        inFlight = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.inFlight = nil }
            self.perform(work)
        }
    }

    private func perform(_ work: Work) {
        switch work {
        case .owner(let mark):
            applyOwner(mark)
        case .reassert:
            reassertNow()
        }
    }

    private func reassertNow() {
        guard !inspector.hasCustomIcon(atBundleAt: bundlePath),
              let cached = config.cachedIconMark() else {
            return
        }
        applyOwner(cached)
    }

    private func applyOwner(_ mark: JournalMark) {
        guard let validated = JournalMark.validate(mark) else {
            fallbackToGeneric(reason: "journal icon mark failed validation")
            return
        }

        config.setCachedIconMark(validated)
        guard JournalIconCompositor.tile(spec: validated, side: 512).kind == .owner else {
            fallbackToGeneric(reason: "journal icon compositor rendered generic")
            return
        }

        let image = JournalIconCompositor.appIcon(spec: validated)
        guard applier.apply(image, toBundleAt: bundlePath) else {
            fallbackToGeneric(reason: "journal icon setIcon returned false")
            return
        }

        applier.setDockImage(image)
        config.iconMarkAppliedAtLeastOnce = true
    }

    private func fallbackToGeneric(reason: String) {
        logger.notice("journal icon fallback to generic: \(reason)")
        _ = applier.clearCustomIcon(atBundleAt: bundlePath)
        applier.setDockImage(nil)
    }
}
