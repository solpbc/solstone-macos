// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation

internal protocol LogExportFileWriting: Sendable {
    func writeAtomically(_ data: Data, to destination: URL) -> Result<Void, Error>
}

internal struct LogExportAtomicWriter: LogExportFileWriting {
    func writeAtomically(_ data: Data, to destination: URL) -> Result<Void, Error> {
        let stagingURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: stagingURL)
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            return .failure(error)
        }
        if Darwin.rename(stagingURL.path, destination.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: stagingURL)
            return .failure(NSError(domain: NSPOSIXErrorDomain, code: Int(code)))
        }
        return .success(())
    }
}
