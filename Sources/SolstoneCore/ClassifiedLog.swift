// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import os

public enum ClassifiedLogLevel: String, Sendable, Equatable {
    case info
    case notice
    case warning
    case error
}

public struct ClassifiedLogEmission: Sendable, Equatable {
    public var level: ClassifiedLogLevel
    public var classification: String
    public var publicFields: [String: String]

    public init(level: ClassifiedLogLevel, classification: String, publicFields: [String: String] = [:]) {
        self.level = level
        self.classification = classification
        self.publicFields = publicFields
    }
}

public protocol ClassifiedLogSinking: Sendable {
    func emit(_ emission: ClassifiedLogEmission)
}

public struct LoggerClassifiedLogSink: ClassifiedLogSinking {
    public static let general = LoggerClassifiedLogSink(logger: .general)
    public static let journal = LoggerClassifiedLogSink(logger: .journal)
    public static let upload = LoggerClassifiedLogSink(logger: .upload)
    public static let setup = LoggerClassifiedLogSink(logger: .setup)

    private let logger: Logger

    public init(logger: Logger) {
        self.logger = logger
    }

    public func emit(_ emission: ClassifiedLogEmission) {
        let fields = emission.publicFields.keys.sorted().map { key in
            "\(key)=\(emission.publicFields[key] ?? "")"
        }.joined(separator: " ")
        let message = fields.isEmpty ? emission.classification : "\(emission.classification) \(fields)"
        switch emission.level {
        case .info:
            logger.info("\(message, privacy: .public)")
        case .notice:
            logger.notice("\(message, privacy: .public)")
        case .warning:
            logger.warning("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }
    }
}
