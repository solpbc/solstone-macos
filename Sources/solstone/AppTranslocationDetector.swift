// SPDX-License-Identifier: AGPL-3.0-only
//
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import os
import SolstoneCore

public enum AppTranslocationDetector {
    public static func isTranslocated() -> Bool {
        let bundlePath = Bundle.main.bundleURL.path
        let pathHeuristic = bundlePath.contains("/AppTranslocation/")
        let apiResult = lookupAPIResult(bundleURL: Bundle.main.bundleURL)

        if apiResult == false && pathHeuristic {
            Logger.setup.warning("translocation api/path mismatch — treating as translocated")
            return true
        }

        return isTranslocated(bundlePath: bundlePath, apiResult: apiResult)
    }

    internal static func isTranslocated(bundlePath: String, apiResult: Bool?) -> Bool {
        if let apiResult {
            return apiResult
        }

        return bundlePath.contains("/AppTranslocation/")
    }

    private typealias SecTranslocateIsTranslocatedURLFn =
        @convention(c) (CFURL, UnsafeMutablePointer<Bool>?, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> UInt8

    private static func lookupAPIResult(bundleURL: URL) -> Bool? {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW) else {
            Logger.setup.warning("translocation api unavailable, falling back to path heuristic")
            return nil
        }
        defer { dlclose(handle) }

        // The live framework exports this symbol, but the macOS 15 SDK stub and headers do not declare it.
        guard let symbol = dlsym(handle, "SecTranslocateIsTranslocatedURL") else {
            Logger.setup.warning("translocation api unavailable, falling back to path heuristic")
            return nil
        }

        let function = unsafeBitCast(symbol, to: SecTranslocateIsTranslocatedURLFn.self)
        var translocated = false
        var error: Unmanaged<CFError>?
        let didResolve = function(bundleURL as CFURL, &translocated, &error)
        error?.release()

        guard didResolve != 0 else {
            return nil
        }

        return translocated
    }
}
