// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation

/// Information extracted from an on-screen window dictionary
public struct OnScreenWindowRecord: Equatable, Sendable {
    public let windowID: CGWindowID
    public let ownerName: String
    public let title: String

    public init(windowID: CGWindowID, ownerName: String, title: String) {
        self.windowID = windowID
        self.ownerName = ownerName
        self.title = title
    }
}

/// Provides access to on-screen window information from the window server
public enum OnScreenWindowList {
    /// Wraps `CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)` returning an empty array on nil.
    public static func copyOnScreenInfo() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? []
    }

    /// Pure parser applying layer == 0 check and extracting records with owner name, title, and window ID.
    public static func layer0Records(from windowList: [[String: Any]]) -> [OnScreenWindowRecord] {
        var records: [OnScreenWindowRecord] = []
        for window in windowList {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else {
                continue
            }
            guard let windowID = window[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }
            let ownerName = window[kCGWindowOwnerName as String] as? String ?? ""
            let title = window[kCGWindowName as String] as? String ?? ""
            records.append(OnScreenWindowRecord(windowID: windowID, ownerName: ownerName, title: title))
        }
        return records
    }

    /// Fetches live on-screen layer-0 windows.
    public static func onScreenLayer0Windows() -> [OnScreenWindowRecord] {
        layer0Records(from: copyOnScreenInfo())
    }
}
