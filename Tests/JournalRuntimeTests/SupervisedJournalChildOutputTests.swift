// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import JournalRuntime

@Suite("SupervisedJournalChildOutput")
struct SupervisedJournalChildOutputTests {
    @Test func ac1_drainHelperDoesNotStallWriterOnOversizedPipe() async throws {
        let pipe = Pipe()
        let handler = SupervisedJournalChildOutputHandler(sink: NoOpSupervisedJournalChildOutputSink())
        let readHandle = pipe.fileHandleForReading
        let writeHandle = pipe.fileHandleForWriting
        readHandle.readabilityHandler = { handle in
            consumeSupervisedJournalChildOutput(from: handle, stream: .stdout, handler: handler)
        }
        let payload = Data(repeating: 0x61, count: 128 * 1024)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try writeHandle.write(contentsOf: payload)
                try writeHandle.close()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw DrainStallError()
            }
            try await group.next()
            group.cancelAll()
        }
        readHandle.readabilityHandler = nil
    }

    @Test func ac2_markerBytesDoNotAppearInEmissions() {
        let sink = RecordingSupervisedJournalChildOutputSink()
        let handler = SupervisedJournalChildOutputHandler(sink: sink)
        let marker = "AC2-UNIQUE-CHILD-MARKER-7f3a"
        handler.consume(stream: .stdout, data: Data("hello \(marker) world".utf8))
        handler.end(exitStatus: 0)

        #expect(!sink.facts.isEmpty)
        for fact in sink.facts {
            #expect(!stringify(fact).contains(marker))
        }
    }

    @Test func ac3_ac4_ac5_handlerPathEmitsUnrecognizedFactsWithoutContent() throws {
        let sink = RecordingSupervisedJournalChildOutputSink()
        let handler = SupervisedJournalChildOutputHandler(sink: sink)
        handler.consume(stream: .stderr, data: Data("foreign child payload".utf8))
        handler.consume(stream: .stderr, data: Data("more foreign payload".utf8))
        handler.end(exitStatus: 1)

        let first = try #require(sink.facts.first { $0.kind == .firstUnrecognized })
        #expect(first.stream == .stderr)
        #expect(first.cause == .unrecognized)
        #expect(first.byteCount == Data("foreign child payload".utf8).count)
        #expect(first.empty == false)
        #expect(first.utf8 == true)

        let stderrEnd = try #require(sink.facts.first { $0.kind == .streamEnd && $0.stream == .stderr })
        #expect(stderrEnd.totalBytes == first.byteCount + Data("more foreign payload".utf8).count)
        #expect(stderrEnd.empty == false)
        #expect(stderrEnd.utf8 == true)
        #expect(stderrEnd.exitStatus == 1)
        #expect(stderrEnd.cause == .unrecognized)
    }

    @Test func ac4_emptyAvailableDataEndsStreamWithoutFlood() throws {
        let sink = RecordingSupervisedJournalChildOutputSink()
        let handler = SupervisedJournalChildOutputHandler(sink: sink)
        handler.consume(stream: .stdout, data: Data())
        handler.consume(stream: .stdout, data: Data())
        handler.end(exitStatus: 0)

        let stdoutEnds = sink.facts.filter { $0.kind == .streamEnd && $0.stream == .stdout }
        #expect(stdoutEnds.count == 1)
        let stdoutEnd = try #require(stdoutEnds.first)
        #expect(stdoutEnd.empty == true)
        #expect(stdoutEnd.totalBytes == 0)
        #expect(stdoutEnd.exitStatus == 0)
    }

    @Test func ac4_nonUTF8StillEmitsUtf8False() {
        let sink = RecordingSupervisedJournalChildOutputSink()
        let handler = SupervisedJournalChildOutputHandler(sink: sink)
        handler.consume(stream: .stdout, data: Data([0xFF, 0xFE, 0xFD]))
        handler.end(exitStatus: nil)

        #expect(sink.facts[0].kind == .firstUnrecognized)
        #expect(sink.facts[0].utf8 == false)
        #expect(sink.facts[0].byteCount == 3)
        #expect(sink.facts[1].kind == .streamEnd)
        #expect(sink.facts[1].utf8 == false)
    }

    private func stringify(_ fact: SupervisedJournalChildOutputFact) -> String {
        "\(fact.kind.rawValue) \(fact.stream.rawValue) \(fact.cause.rawValue) \(fact.byteCount) \(fact.totalBytes) \(fact.utf8) \(fact.empty) \(fact.exitStatus.map(String.init) ?? "")"
    }
}

private struct DrainStallError: Error {}

private final class RecordingSupervisedJournalChildOutputSink: SupervisedJournalChildOutputSinking, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SupervisedJournalChildOutputFact] = []

    func emit(_ fact: SupervisedJournalChildOutputFact) {
        lock.lock()
        storage.append(fact)
        lock.unlock()
    }

    var facts: [SupervisedJournalChildOutputFact] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private struct NoOpSupervisedJournalChildOutputSink: SupervisedJournalChildOutputSinking {
    func emit(_ fact: SupervisedJournalChildOutputFact) {}
}
