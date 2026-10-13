// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
@preconcurrency import ScreenCaptureKit

/// Check if an error indicates a permission/TCC denial that will never self-heal
public func isPermissionError(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == SCStreamErrorDomain
        && nsError.code == SCStreamError.Code.userDeclined.rawValue
}

/// Check if an error indicates the user stopped stream capture via macOS Stop Sharing (a terminal user action, not a permission denial).
public func isUserStoppedStreamError(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == SCStreamErrorDomain
        && nsError.code == SCStreamError.Code.userStopped.rawValue
}
