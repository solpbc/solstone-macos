// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
@preconcurrency import ScreenCaptureKit

/// Shared SCStream error delegate — forwards `didStopWithError` to a closure
final class StreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    let onError: (Error) -> Void

    init(onError: @escaping (Error) -> Void) {
        self.onError = onError
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError(error)
    }
}
