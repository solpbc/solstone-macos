// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SolstoneCore

enum SupervisedJournalChildOutputStream: String, Sendable, Equatable {
    case stdout
    case stderr
}

enum SupervisedJournalChildOutputCause: String, Sendable, Equatable {
    case unrecognized
}

enum SupervisedJournalChildOutputKind: String, Sendable, Equatable {
    case firstUnrecognized
    case streamEnd
}

struct SupervisedJournalChildOutputFact: Sendable, Equatable {
    var kind: SupervisedJournalChildOutputKind
    var stream: SupervisedJournalChildOutputStream
    var cause: SupervisedJournalChildOutputCause
    var byteCount: Int
    var totalBytes: Int
    var utf8: Bool
    var empty: Bool
    var exitStatus: Int32?
}

protocol SupervisedJournalChildOutputSinking: Sendable {
    func emit(_ fact: SupervisedJournalChildOutputFact)
}

struct LoggerSupervisedJournalChildOutputSink: SupervisedJournalChildOutputSinking {
    func emit(_ fact: SupervisedJournalChildOutputFact) {
        let stream = fact.stream.rawValue
        let cause = fact.cause.rawValue
        let utf8 = fact.utf8 ? "true" : "false"
        let empty = fact.empty ? "true" : "false"
        switch fact.kind {
        case .firstUnrecognized:
            let byteCount = fact.byteCount
            Logger.journal.notice(
                "journal-lifecycle: child-output stream=\(stream, privacy: .public) cause=\(cause, privacy: .public) byteCount=\(byteCount, privacy: .public) utf8=\(utf8, privacy: .public) empty=\(empty, privacy: .public)"
            )
        case .streamEnd:
            let totalBytes = fact.totalBytes
            if let exitStatus = fact.exitStatus {
                Logger.journal.notice(
                    "journal-lifecycle: child-output-end stream=\(stream, privacy: .public) totalBytes=\(totalBytes, privacy: .public) utf8=\(utf8, privacy: .public) empty=\(empty, privacy: .public) exit=\(exitStatus, privacy: .public)"
                )
            } else {
                Logger.journal.notice(
                    "journal-lifecycle: child-output-end stream=\(stream, privacy: .public) totalBytes=\(totalBytes, privacy: .public) utf8=\(utf8, privacy: .public) empty=\(empty, privacy: .public)"
                )
            }
        }
    }
}

final class SupervisedJournalChildOutputHandler: @unchecked Sendable {
    private struct StreamState {
        var totalBytes = 0
        var utf8 = true
        var emittedFirstUnrecognized = false
        var ended = false
    }

    private let lock = NSLock()
    private let sink: any SupervisedJournalChildOutputSinking
    private var states: [SupervisedJournalChildOutputStream: StreamState] = [
        .stdout: StreamState(),
        .stderr: StreamState(),
    ]

    init(sink: any SupervisedJournalChildOutputSinking = LoggerSupervisedJournalChildOutputSink()) {
        self.sink = sink
    }

    func consume(stream: SupervisedJournalChildOutputStream, data: Data) {
        let fact: SupervisedJournalChildOutputFact? = lock.withLock {
            var state = states[stream] ?? StreamState()
            guard !state.ended else { return nil }
            guard !data.isEmpty else { return nil }

            if String(data: data, encoding: .utf8) == nil {
                state.utf8 = false
            }
            state.totalBytes += data.count

            if state.emittedFirstUnrecognized {
                states[stream] = state
                return nil
            }

            state.emittedFirstUnrecognized = true
            states[stream] = state
            return SupervisedJournalChildOutputFact(
                kind: .firstUnrecognized,
                stream: stream,
                cause: .unrecognized,
                byteCount: data.count,
                totalBytes: state.totalBytes,
                utf8: state.utf8,
                empty: false,
                exitStatus: nil
            )
        }
        if let fact {
            sink.emit(fact)
        }
    }

    func end(exitStatus: Int32?) {
        let facts: [SupervisedJournalChildOutputFact] = lock.withLock {
            var emitted: [SupervisedJournalChildOutputFact] = []
            for stream in [SupervisedJournalChildOutputStream.stdout, .stderr] {
                var state = states[stream] ?? StreamState()
                guard !state.ended else { continue }
                state.ended = true
                states[stream] = state
                emitted.append(
                    SupervisedJournalChildOutputFact(
                        kind: .streamEnd,
                        stream: stream,
                        cause: .unrecognized,
                        byteCount: 0,
                        totalBytes: state.totalBytes,
                        utf8: state.utf8,
                        empty: state.totalBytes == 0,
                        exitStatus: exitStatus
                    )
                )
            }
            return emitted
        }
        for fact in facts {
            sink.emit(fact)
        }
    }
}

func consumeSupervisedJournalChildOutput(
    from handle: FileHandle,
    stream: SupervisedJournalChildOutputStream,
    handler: SupervisedJournalChildOutputHandler
) {
    let data = handle.availableData
    handler.consume(stream: stream, data: data)
}
