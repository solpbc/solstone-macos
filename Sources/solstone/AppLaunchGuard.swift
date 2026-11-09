// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation

/// What a launch does with its command line, decided before any app state exists.
enum AppCommandLine {
    enum Decision: Equatable {
        case launch
        case usage(exitCode: Int32)
    }

    /// `main` handles the app's own commands first, so any word left here is unknown.
    /// A single-dash first argument belongs to AppKit (`-NSDocumentRevisionsDebugMode YES`).
    static func decision(arguments: [String]) -> Decision {
        guard let first = arguments.dropFirst().first else { return .launch }
        if first == "-h" || first == "--help" || first == "help" { return .usage(exitCode: 0) }
        if first.hasPrefix("-"), !first.hasPrefix("--") { return .launch }
        return .usage(exitCode: 64)
    }
}

/// One solstone app per account. Launch Services stops a second copy on its own, but running
/// the binary directly does not, and a second copy would run startup recovery against the
/// stores the first one is still writing.
enum AppInstanceLock {
    enum Outcome: Equatable {
        /// This process owns the app. The descriptor stays open until the process ends,
        /// and the kernel drops the lock however that happens.
        case acquired(descriptor: Int32)
        case heldElsewhere
        /// The lock could not be checked. Starting is still right: an unwritable support
        /// directory must not keep the only copy of the app from opening.
        case unavailable
    }

    static func acquire(
        at url: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Solstone/app.lock")
    ) -> Outcome {
        guard let url else { return .unavailable }
        guard (try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )) != nil else { return .unavailable }
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return .unavailable }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return .acquired(descriptor: descriptor) }
        let failure = errno
        close(descriptor)
        return failure == EWOULDBLOCK ? .heldElsewhere : .unavailable
    }
}
