// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
@preconcurrency import ScreenCaptureKit
import Testing
@testable import solstone

@Suite("Permission error classification")
struct PermissionErrorClassificationTests {
    @Test func screenCaptureKitUserDeclinedIsPermissionErrorWithoutEnglishText() {
        let error = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.userDeclined.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Zugriff abgelehnt"]
        )

        #expect(isPermissionError(error))
    }

    @Test func englishDeclinedTextOnWrongDomainIsNotPermissionError() {
        let error = NSError(
            domain: "not.ScreenCaptureKit",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The user declined screen capture"]
        )

        #expect(!isPermissionError(error))
    }
}
