// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
@preconcurrency import ScreenCaptureKit

internal protocol CaptureStreamControlling: AnyObject, Sendable {
    func addStreamOutput(_ output: any SCStreamOutput, type: SCStreamOutputType, sampleHandlerQueue: DispatchQueue?) throws
    func startCapture() async throws
    func stopCapture() async throws
    func updateContentFilter(_ filter: SCContentFilter) async throws
}

extension SCStream: CaptureStreamControlling {}

internal typealias CaptureStreamFactory = @MainActor (
    _ filter: SCContentFilter,
    _ configuration: SCStreamConfiguration,
    _ delegate: StreamDelegate
) -> any CaptureStreamControlling

internal let defaultCaptureStreamFactory: CaptureStreamFactory = { filter, configuration, delegate in
    SCStream(filter: filter, configuration: configuration, delegate: delegate)
}
