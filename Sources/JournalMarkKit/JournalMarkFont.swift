// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import CoreText
import Foundation
import os
import SolstoneCore

public enum JournalMarkFont {
    private static let fontName = "Comfortaa-Bold"
    private static let fontSize: CGFloat = 19

    @MainActor
    public private(set) static var isRegistered = false

    @MainActor
    public static func register() {
        guard !isRegistered else { return }
        guard let url = Bundle.module.url(forResource: fontName, withExtension: "ttf", subdirectory: "Resources") else {
            Logger.journalMark.error("journal-mark font registration failed: resource missing")
            return
        }

        var registrationError: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &registrationError)
        guard let font = NSFont(name: fontName, size: fontSize) else {
            let detail = registrationError
                .map { CFErrorCopyDescription($0.takeRetainedValue()) as String }
                ?? "font probe returned nil"
            Logger.journalMark.error("journal-mark font registration failed: \(detail, privacy: .public)")
            isRegistered = false
            return
        }

        isRegistered = true
        Logger.journalMark.info("journal-mark font registered: name=\(font.fontName, privacy: .public) family=\(font.familyName ?? "<unknown>", privacy: .public) registered=\(registered, privacy: .public)")
    }
}
