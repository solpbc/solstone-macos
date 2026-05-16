// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("InstallerJSONLEvents")
struct InstallerJSONLEventsTests {
    @Test func parsesAndRendersEachEventType() {
        assertEvent(
            #"{"event":"setup.started","version":"0.2.1","mode":"non_interactive"}"#,
            .setupStarted(version: "0.2.1", mode: "non_interactive"),
            "setup started (version 0.2.1, non_interactive)"
        )
        assertEvent(
            #"{"event":"step.started","step":"doctor","index":1,"total":6}"#,
            .stepStarted(step: "doctor", index: 1, total: 6),
            "step 1/6: doctor"
        )
        assertEvent(
            #"{"event":"step.started","step":"skills_user","index":4,"total":7}"#,
            .stepStarted(step: "skills_user", index: 4, total: 7),
            "step 4/7: skills_user"
        )
        assertEvent(
            #"{"event":"doctor.started","version":"0.2.1"}"#,
            .doctorStarted(version: "0.2.1"),
            "doctor started"
        )
        assertEvent(
            #"{"event":"check.completed","name":"python_version","severity":"blocker","status":"ok","detail":"python ok","fix":""}"#,
            .checkCompleted(name: "python_version", severity: "blocker", status: "ok", detail: "python ok", fix: ""),
            "  [ok] python_version - python ok"
        )
        assertEvent(
            #"{"event":"doctor.completed","status":"warning","duration_ms":422,"summary":{"total":17,"failed":0,"warnings":3,"skipped":5}}"#,
            .doctorCompleted(status: "warning", durationMS: 422, summary: DoctorSummary(total: 17, failed: 0, warnings: 3, skipped: 5)),
            "doctor: 17 checks (0 failed, 3 warnings, 5 skipped)"
        )
        assertEvent(
            #"{"event":"step.completed","step":"doctor","outcome":"ok","duration_ms":121}"#,
            .stepCompleted(step: "doctor", outcome: "ok", reason: nil, durationMS: 121),
            "step doctor done (ok, 121ms)"
        )
        assertEvent(
            #"{"event":"step.completed","step":"skills_journal","outcome":"ok","duration_ms":42}"#,
            .stepCompleted(step: "skills_journal", outcome: "ok", reason: nil, durationMS: 42),
            "step skills_journal done (ok, 42ms)"
        )
        assertEvent(
            #"{"event":"step.completed","step":"skills_user","outcome":"skipped","reason":"--skip-skills"}"#,
            .stepCompleted(step: "skills_user", outcome: "skipped", reason: "--skip-skills", durationMS: nil),
            "step skills_user skipped (--skip-skills)"
        )
        assertEvent(
            #"{"event":"step.warning","step":"doctor","text":"port in use","fix_hint":"kill 123"}"#,
            .stepWarning(step: "doctor", text: "port in use", fixHint: "kill 123"),
            "  warn: port in use (fix: kill 123)"
        )
        assertEvent(
            #"{"event":"step.failed","step":"doctor","error":{"code":"port_in_use_non_interactive","message":"port failed","details":"","exit_code":2}}"#,
            .stepFailed(step: "doctor", errorCode: "port_in_use_non_interactive", message: "port failed", details: "", exitCode: 2),
            "step doctor failed: port failed"
        )
        assertEvent(
            #"{"event":"setup.completed","status":"ok","duration_ms":4000}"#,
            .setupCompleted(status: "ok", durationMS: 4000, failedStep: nil),
            "setup ok (4000ms)"
        )
    }

    @Test func rendersAlternateStatusesAndSkippedStep() {
        assertEvent(
            #"{"event":"check.completed","name":"port_5015_free","status":"warning","detail":"port busy"}"#,
            .checkCompleted(name: "port_5015_free", severity: nil, status: "warning", detail: "port busy", fix: nil),
            "  [warn] port_5015_free - port busy"
        )
        assertEvent(
            #"{"event":"check.completed","name":"launchd_stale_plist","status":"skipped","detail":"launchd plist absent"}"#,
            .checkCompleted(name: "launchd_stale_plist", severity: nil, status: "skipped", detail: "launchd plist absent", fix: nil),
            "  [skip] launchd_stale_plist - launchd plist absent"
        )
        assertEvent(
            #"{"event":"step.completed","step":"install_models","outcome":"skipped","reason":"--skip-models"}"#,
            .stepCompleted(step: "install_models", outcome: "skipped", reason: "--skip-models", durationMS: nil),
            "step install_models skipped (--skip-models)"
        )
        assertEvent(
            #"{"event":"setup.completed","status":"failed","failed_step":"doctor"}"#,
            .setupCompleted(status: "failed", durationMS: nil, failedStep: "doctor"),
            "setup failed at doctor"
        )
    }

    @Test func negativeCasesClassifyRawLines() {
        #expect(SetupEventParser.parse(line: "{") == .malformed("{"))
        #expect(SetupEventParser.parse(line: #"{"event":"future.event"}"#) == .unrecognized(#"{"event":"future.event"}"#))
        #expect(SetupEventParser.parse(line: "   ") == .unparseableLine("   "))
        #expect(SetupEventParser.parse(line: #"{"event":"step.started""#) == .malformed(#"{"event":"step.started""#))
    }

    @Test func extraFieldsAreTolerated() {
        assertEvent(
            #"{"event":"step.started","step":"doctor","index":1,"total":6,"hint":"future"}"#,
            .stepStarted(step: "doctor", index: 1, total: 6),
            "step 1/6: doctor"
        )
    }

    @Test func setupStartedMissingVersionRendersPlainly() {
        assertEvent(
            #"{"event":"setup.started","mode":"non_interactive"}"#,
            .setupStarted(version: nil, mode: "non_interactive"),
            "setup started"
        )
    }

    @Test func rendererSkipsEmptyUnparseableLines() {
        var renderer = EventRenderer()
        renderer.append(.unparseableLine(""))
        renderer.append(.unparseableLine("  "))
        #expect(renderer.renderedLog == "")
    }

    @Test func upstreamSetupEventsDocDrift() throws {
        let path = NSString(string: "~/projects/solstone/solstone/think/setup_events.py").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            print("skipping doc-drift: upstream solstone repo not available")
            return
        }

        let content = try String(contentsOfFile: path, encoding: .utf8)
        assertValues(named: "EVENT_TYPES", in: content, areRepresentedBy: InstallerKnownValues.eventTypes)
        assertValues(named: "ERROR_CODES", in: content, areRepresentedBy: InstallerKnownValues.errorCodes)
        assertValues(named: "STEP_NAMES", in: content, areRepresentedBy: InstallerKnownValues.stepNames)
        assertValues(named: "SKIPPED_REASONS", in: content, areRepresentedBy: InstallerKnownValues.skippedReasons)

        let statusValues = Array(InstallerKnownValues.statusTranslation.keys) + Array(InstallerKnownValues.statusTranslation.values)
        assertValues(named: "STATUS_TRANSLATION", in: content, areRepresentedBy: statusValues)
    }

    private func assertEvent(_ line: String, _ expected: SetupEvent, _ rendered: String) {
        let parsed = SetupEventParser.parse(line: line)
        #expect(parsed == .event(expected))
        guard case .event(let event) = parsed else { return }
        var renderer = EventRenderer()
        renderer.append(event)
        #expect(renderer.renderedLog == rendered + "\n")
    }

    private func assertValues(named name: String, in content: String, areRepresentedBy swiftValues: [String]) {
        let values = quotedValues(in: block(named: name, in: content))
        for value in values {
            #expect(swiftValues.contains(value))
        }
    }

    private func block(named name: String, in content: String) -> String {
        guard let start = content.range(of: name) else { return "" }
        let rest = content[start.lowerBound...]
        guard let end = rest.range(of: "\n\n") else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }

    private func quotedValues(in text: String) -> [String] {
        let pattern = #""([^"]+)""#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex?.matches(in: text, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[valueRange])
        } ?? []
    }
}
