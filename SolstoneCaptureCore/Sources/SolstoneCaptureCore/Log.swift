// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

/// Unified logging API that writes to both os.Logger (Console.app) and FileLogger (text files)
public enum Log {
    private static let logger = Logger(subsystem: "com.solstone.capture", category: "general")
    private static let uploadLogger = Logger(subsystem: "com.solstone.capture", category: "upload")

    /// Log an informational message
    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        FileLogger.shared.write("[INFO] \(message)")
    }

    /// Log a warning message
    public static func warn(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        FileLogger.shared.write("[WARN] \(message)")
    }

    /// Log an error message
    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        FileLogger.shared.write("[ERROR] \(message)")
    }

    /// Log an upload-related message
    public static func upload(_ message: String) {
        uploadLogger.info("\(message, privacy: .public)")
        FileLogger.shared.write("[UPLOAD] \(message)")
    }

    /// Log a debug message (only when verbose is true)
    public static func debug(_ message: String, verbose: Bool) {
        guard verbose else { return }
        logger.debug("\(message, privacy: .public)")
        FileLogger.shared.write("[DEBUG] \(message)")
    }
}
