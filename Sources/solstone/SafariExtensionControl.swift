// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Foundation
import SafariServices

/// Reads whether the owner has turned the solstone extension on in Safari, and
/// opens Safari's extension settings at it. Closures so tests never reach Safari.
public struct SafariExtensionControl: Sendable {
    public var readState: @Sendable (_ done: @escaping @Sendable (SafariExtensionAXState) -> Void) -> Void
    public var showSettings: @Sendable (_ done: @escaping @Sendable (Bool) -> Void) -> Void

    public init(
        readState: @escaping @Sendable (_ done: @escaping @Sendable (SafariExtensionAXState) -> Void) -> Void,
        showSettings: @escaping @Sendable (_ done: @escaping @Sendable (Bool) -> Void) -> Void
    ) {
        self.readState = readState
        self.showSettings = showSettings
    }

    // SafariServices replies on its own queue; the async forms keep Swift's
    // executor checks out of those replies.
    public static let live = SafariExtensionControl(
        readState: { done in
            Task.detached {
                let state = try? await SFSafariExtensionManager.stateOfSafariExtension(
                    withIdentifier: SafariExtensionBridge.extensionIdentifier
                )
                done(state.map { $0.isEnabled ? .on : .off } ?? .unknown)
            }
        },
        showSettings: { done in
            Task.detached {
                do {
                    try await SFSafariApplication.showPreferencesForExtension(
                        withIdentifier: SafariExtensionBridge.extensionIdentifier
                    )
                    done(true)
                } catch {
                    done(false)
                }
            }
        }
    )
}

#endif
