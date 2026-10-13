// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import CoreGraphics
import Foundation
import Testing

func expectClose(
    _ actual: CGFloat,
    _ expected: CGFloat,
    tolerance: CGFloat = 0.01,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(abs(actual - expected) <= tolerance, "expected \(actual) ~= \(expected)", sourceLocation: sourceLocation)
}

func expectRectClose(
    _ actual: CGRect,
    _ expected: CGRect,
    tolerance: CGFloat = 0.01,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    expectClose(actual.minX, expected.minX, tolerance: tolerance, sourceLocation: sourceLocation)
    expectClose(actual.minY, expected.minY, tolerance: tolerance, sourceLocation: sourceLocation)
    expectClose(actual.width, expected.width, tolerance: tolerance, sourceLocation: sourceLocation)
    expectClose(actual.height, expected.height, tolerance: tolerance, sourceLocation: sourceLocation)
}
