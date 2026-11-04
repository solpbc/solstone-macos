// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation

/// What went wrong reaching this account's journal. Carries no owner copy: each app words these itself.
public enum JournalLocalHTTPError: Error, Equatable, Sendable {
    /// The endpoint exists but isn't this account's, or something else answered for a journal.
    case refused, notOwnJournal
    /// Nothing usable is answering yet.
    case unavailable
    case invalidResponse, timedOut
}

/// The owner-only runtime record the journal writes beside its socket.
public struct JournalLocalRuntime: Decodable, Equatable, Sendable {
    public let generation: String
    public let journalRoot: String
    public let tcpPort: Int
    public let socketPath: String

    enum CodingKeys: String, CodingKey {
        case generation
        case journalRoot = "journal_root"
        case tcpPort = "tcp_port"
        case socketPath = "socket_path"
    }

    public init(generation: String, journalRoot: String, tcpPort: Int, socketPath: String) {
        self.generation = generation
        self.journalRoot = journalRoot
        self.tcpPort = tcpPort
        self.socketPath = socketPath
    }
}

public enum JournalLocalEndpoint {
    /// The journal's default browser port. Only ever used when no runtime record names another.
    public static let defaultTCPPort = 5015

    public static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String? {
        if let override = environment["SOLSTONE_JOURNAL_SOCKET"] {
            if override.isEmpty { return nil }
            return try checkedPath(override)
        }
        let count = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard count > 0 else { throw JournalLocalHTTPError.unavailable }
        var bytes = [CChar](repeating: 0, count: count)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &bytes, count) == count else { throw JournalLocalHTTPError.unavailable }
        let directory = String(decoding: bytes.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return try checkedPath(URL(fileURLWithPath: directory).appendingPathComponent("solstone/journal.sock").path)
    }

    /// The record beside the socket, or nil when there is none. An unreadable one is an error, never "none".
    public static func runtimeRecord(socket: String?) throws -> JournalLocalRuntime? {
        guard let socket else { return nil }
        let url = URL(fileURLWithPath: socket).deletingLastPathComponent().appendingPathComponent("journal.json")
        do {
            return try JSONDecoder().decode(JournalLocalRuntime.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw JournalLocalHTTPError.unavailable
        }
    }

    /// The TCP port this account's journal says it serves, when it has said.
    public static func runtimeTCPPort(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int? {
        (try? runtimeRecord(socket: socketPath(environment: environment)))?.tcpPort
    }

    /// False only when nothing is at the path. A socket owned by anyone else, or anything that isn't a socket, is refused.
    public static func socketExists(_ path: String) throws -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw JournalLocalHTTPError.refused
        }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() else {
            throw JournalLocalHTTPError.refused
        }
        return true
    }

    private static func checkedPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count < 104 else {
            throw JournalLocalHTTPError.unavailable
        }
        return path
    }
}
