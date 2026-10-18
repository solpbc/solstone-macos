// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
import MacTestSupport
import SPLTunnel
import Testing
@testable import solstone

@Suite("Supporting connection verification")
@MainActor
struct SupportingConnectionTests {
    @Test(arguments: ["mode", "retired", "credential", "cancel", "phase"])
    func delayedPairStartRechecksBeforeCeremony(change: String) async throws {
        let gate = OneShotContinuationGate()
        defer { gate.release() }
        let entered = LockedCounter()
        var active = true
        var noneHeld = true
        var submitted = 0
        let pending = Task {
            await verifySupportingConnection(
                expectedInstanceID: expectedInstance, expectedCAFingerprint: sampleFingerprint,
                heldState: .noneHeld, isMarkAlreadyRecorded: false,
                operationIsCurrent: { active && !Task.isCancelled },
                mayStartCeremony: { noneHeld && !Task.isCancelled },
                captureAdmission: { nil }, confirmAdmission: { _ in false },
                startPairing: {
                    entered.increment()
                    await gate.wait()
                    return .success(makePairStartResponse(pairLink: makeValidPairLink(fingerprint: sampleFingerprint), fingerprint: sampleFingerprint))
                },
                submit: { _ in submitted += 1; return .paired },
                durableInstanceID: { nil }, resolveIdentity: { .absent }, record: { _, _ in false }
            )
        }
        try await waitUntil { entered.count == 1 }
        switch change {
        case "mode", "retired": active = false
        case "credential": noneHeld = false
        case "cancel": pending.cancel()
        default: break // A permission-phase transition preserves the active intent.
        }
        gate.release()
        _ = await pending.value
        #expect(submitted == (change == "phase" ? 1 : 0))
    }

    private enum TestCrockford32 {
        static func encode(_ bytes: [UInt8]) -> String {
            let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
            var accumulator: UInt64 = 0
            var bitCount = 0
            var output = ""

            for byte in bytes {
                accumulator = (accumulator << 8) | UInt64(byte)
                bitCount += 8

                while bitCount >= 5 {
                    bitCount -= 5
                    let index = Int((accumulator >> UInt64(bitCount)) & 0x1f)
                    output.append(alphabet[index])
                    accumulator &= (1 << UInt64(bitCount)) - 1
                }
            }

            if bitCount > 0 {
                let index = Int((accumulator >> UInt64(5 - bitCount)) & 0x1f)
                output.append(alphabet[index])
            }

            return output
        }
    }

    private let sampleFingerprint = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    private let expectedInstance = "inst-supporting-1"

    private func makeDefaultAdmission(
        expectedInstance: String = "inst-supporting-1",
        expectedFingerprint: String = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        revision: String = "rev-1",
        caMatches: Bool = true
    ) -> SupportingAdmission {
        SupportingAdmission(
            revision: PairingCredentialRevision(fingerprint: expectedFingerprint, revision: revision),
            instanceID: expectedInstance,
            caMatches: caMatches
        )
    }

    private func makeValidPairLink(fingerprint: String) -> String {
        guard let prefix16 = decodeHexPrefix16(fingerprint) else {
            fatalError("Invalid test fingerprint")
        }
        var bytes = [UInt8](repeating: 0, count: 40)
        bytes[0] = 0x04 // direct pair link with certificateSHA256 pin
        bytes[1] = 0x01 // IPv4
        bytes[2] = 127
        bytes[3] = 0
        bytes[4] = 0
        bytes[5] = 1 // 127.0.0.1
        bytes[6] = 0x1b
        bytes[7] = 0x9e // port 7070
        for i in 8..<24 {
            bytes[i] = UInt8(i)
        }
        bytes.replaceSubrange(24..<40, with: prefix16)
        return "https://go.solstone.app/p#\(TestCrockford32.encode(bytes))"
    }

    private func makePairStartResponse(pairLink: String, fingerprint: String) -> SameMachinePairStartResponse {
        SameMachinePairStartResponse(
            nonce: "test-nonce",
            pairLink: pairLink,
            expiresIn: 300,
            deviceLabel: "test-device",
            caFingerprint: fingerprint
        )
    }

    @Test func durableIDMatchesAndMarkAlreadyRecordedSkipsPairStartAndResolve() async {
        var startCalled = false
        var submitCalled = false
        var resolveCalled = false
        var recordCalled = false

        let outcome = await verifySupportingConnection(
            expectedInstanceID: expectedInstance,
            expectedCAFingerprint: sampleFingerprint,
            heldState: .noneHeld,
            isMarkAlreadyRecorded: true,
            captureAdmission: { makeDefaultAdmission() },
            confirmAdmission: { _ in true },
            startPairing: {
                startCalled = true
                fatalError("Should not pair-start")
            },
            submit: { _ in
                submitCalled = true
                return .paired
            },
            durableInstanceID: { expectedInstance },
            resolveIdentity: {
                resolveCalled = true
                return .mark(JournalMark.uiTestSample, instanceID: expectedInstance)
            },
            record: { _, _ in
                recordCalled = true
                return true
            }
        )

        #expect(outcome == .alreadyRecorded)
        #expect(!startCalled)
        #expect(!submitCalled)
        #expect(!resolveCalled)
        #expect(!recordCalled)
    }

    @Test func durableIDMatchesAndMarkNotRecordedFetchesIdentityAndRecords() async {
        var startCalled = false
        var submitCalled = false
        var recordedMark: JournalMark?

        let mark = JournalMark.uiTestSample

        let outcome = await verifySupportingConnection(
            expectedInstanceID: expectedInstance,
            expectedCAFingerprint: sampleFingerprint,
            heldState: .noneHeld,
            isMarkAlreadyRecorded: false,
            captureAdmission: { makeDefaultAdmission() },
            confirmAdmission: { _ in true },
            startPairing: {
                startCalled = true
                fatalError("Should not pair-start")
            },
            submit: { _ in
                submitCalled = true
                return .paired
            },
            durableInstanceID: { expectedInstance },
            resolveIdentity: {
                .mark(mark, instanceID: expectedInstance)
            },
            record: { m, _ in
                recordedMark = m
                return true
            }
        )

        #expect(outcome == .recorded(mark))
        #expect(!startCalled)
        #expect(!submitCalled)
        #expect(recordedMark == mark)
    }

    @Test func heldStateNotNoneHeldReturnsNotEligibleWithoutPairStartOrSubmit() async {
        var startCalled = false
        var submitCalled = false

        let outcome = await verifySupportingConnection(
            expectedInstanceID: expectedInstance,
            expectedCAFingerprint: sampleFingerprint,
            heldState: .differentHomeHeld,
            isMarkAlreadyRecorded: false,
            captureAdmission: { makeDefaultAdmission() },
            confirmAdmission: { _ in true },
            startPairing: {
                startCalled = true
                fatalError("Should not pair-start")
            },
            submit: { _ in
                submitCalled = true
                return .paired
            },
            durableInstanceID: { nil },
            resolveIdentity: {
                .absent
            },
            record: { _, _ in false }
        )

        #expect(outcome == .notEligible)
        #expect(!startCalled)
        #expect(!submitCalled)
    }

    @Test func pairStartFailureReturnsPairStartFailed() async {
        var submitCalled = false

        let outcome = await verifySupportingConnection(
            expectedInstanceID: expectedInstance,
            expectedCAFingerprint: sampleFingerprint,
            heldState: .noneHeld,
            isMarkAlreadyRecorded: false,
            captureAdmission: { makeDefaultAdmission() },
            confirmAdmission: { _ in true },
            startPairing: {
                .failure(SameMachinePairStartFailure(kind: .transport, detail: "unreachable"))
            },
            submit: { _ in
                submitCalled = true
                return .paired
            },
            durableInstanceID: { nil },
            resolveIdentity: { .absent },
            record: { _, _ in false }
        )

        #expect(outcome == .pairStartFailed(.transport))
        #expect(!submitCalled)
    }

    @Test func linkVerificationRejectionStopsBeforeSubmit() async {
        var submitCalled = false

        let outcome = await verifySupportingConnection(
            expectedInstanceID: expectedInstance,
            expectedCAFingerprint: sampleFingerprint,
            heldState: .noneHeld,
            isMarkAlreadyRecorded: false,
            captureAdmission: { makeDefaultAdmission() },
            confirmAdmission: { _ in true },
            startPairing: {
                .success(makePairStartResponse(pairLink: "not-a-valid-pair-link", fingerprint: sampleFingerprint))
            },
            verifyLink: { _ in .failure(.unparsable) },
            submit: { _ in
                submitCalled = true
                return .paired
            },
            durableInstanceID: { nil },
            resolveIdentity: { .absent },
            record: { _, _ in false }
        )

        #expect(outcome == .linkRejected(.unparsable))
        #expect(!submitCalled)
    }

    @Test func fingerprintOrPinMismatchStopsBeforeSubmit() async {
        var submitCalled = false
        let validLink = makeValidPairLink(fingerprint: sampleFingerprint)

        // Case 1: response fingerprint doesn't match expected
        let differentFingerprint = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        let outcome1 = await verifySupportingConnection(
            expectedInstanceID: expectedInstance,
            expectedCAFingerprint: sampleFingerprint,
            heldState: .noneHeld,
            isMarkAlreadyRecorded: false,
            captureAdmission: { makeDefaultAdmission() },
            confirmAdmission: { _ in true },
            startPairing: {
                .success(makePairStartResponse(pairLink: validLink, fingerprint: differentFingerprint))
            },
            submit: { _ in
                submitCalled = true
                return .paired
            },
            durableInstanceID: { nil },
            resolveIdentity: { .absent },
            record: { _, _ in false }
        )
        #expect(outcome1 == .fingerprintOrPinMismatch)
        #expect(!submitCalled)

        // Case 2: PIN in pairLink doesn't match expected fingerprint
        let mismatchLink = makeValidPairLink(fingerprint: differentFingerprint)
        let outcome2 = await verifySupportingConnection(
            expectedInstanceID: expectedInstance,
            expectedCAFingerprint: sampleFingerprint,
            heldState: .noneHeld,
            isMarkAlreadyRecorded: false,
            captureAdmission: { makeDefaultAdmission() },
            confirmAdmission: { _ in true },
            startPairing: {
                .success(makePairStartResponse(pairLink: mismatchLink, fingerprint: sampleFingerprint))
            },
            submit: { _ in
                submitCalled = true
                return .paired
            },
            durableInstanceID: { nil },
            resolveIdentity: { .absent },
            record: { _, _ in false }
        )
        #expect(outcome2 == .fingerprintOrPinMismatch)
        #expect(!submitCalled)
    }

    @Test func submitFailsReturnsCeremonyFailed() async {
        let validLink = makeValidPairLink(fingerprint: sampleFingerprint)
        var submitCalls = 0
        var resolveCalled = false

        let outcome = await verifySupportingConnection(
            expectedInstanceID: expectedInstance,
            expectedCAFingerprint: sampleFingerprint,
            heldState: .noneHeld,
            isMarkAlreadyRecorded: false,
            captureAdmission: { makeDefaultAdmission() },
            confirmAdmission: { _ in true },
            startPairing: {
                .success(makePairStartResponse(pairLink: validLink, fingerprint: sampleFingerprint))
            },
            submit: { _ in
                submitCalls += 1
                return .failed(.homeUnreachable)
            },
            durableInstanceID: { nil },
            resolveIdentity: {
                resolveCalled = true
                return .absent
            },
            record: { _, _ in false }
        )

        #expect(outcome == .ceremonyFailed(PairingFlowState.failed(.homeUnreachable)))
        #expect(submitCalls == 1)
        #expect(!resolveCalled)
    }

    @Test func fullCeremonySubmitsOnceAndRecordsMark() async {
        let validLink = makeValidPairLink(fingerprint: sampleFingerprint)
        var submitCalls = 0
        var recordedMark: JournalMark?
        var durableID: String? = nil
        let mark = JournalMark.uiTestSample

        let outcome = await verifySupportingConnection(
            expectedInstanceID: expectedInstance,
            expectedCAFingerprint: sampleFingerprint,
            heldState: .noneHeld,
            isMarkAlreadyRecorded: false,
            captureAdmission: { makeDefaultAdmission() },
            confirmAdmission: { _ in true },
            startPairing: {
                .success(makePairStartResponse(pairLink: validLink, fingerprint: sampleFingerprint))
            },
            submit: { _ in
                submitCalls += 1
                durableID = expectedInstance
                return .paired
            },
            durableInstanceID: { durableID },
            resolveIdentity: {
                .mark(mark, instanceID: expectedInstance)
            },
            record: { m, _ in
                recordedMark = m
                return true
            }
        )

        #expect(outcome == .recorded(mark))
        #expect(submitCalls == 1)
        #expect(recordedMark == mark)
    }

    @Test func uncommittedReturnsStillSettingUpWithoutRecording() async {
        var recordCalled = false

        let outcome = await verifySupportingConnection(
            expectedInstanceID: expectedInstance,
            expectedCAFingerprint: sampleFingerprint,
            heldState: .noneHeld,
            isMarkAlreadyRecorded: false,
            captureAdmission: { makeDefaultAdmission() },
            confirmAdmission: { _ in true },
            startPairing: { fatalError() },
            submit: { _ in fatalError() },
            durableInstanceID: { expectedInstance },
            resolveIdentity: {
                .uncommitted(instanceID: expectedInstance)
            },
            record: { _, _ in
                recordCalled = true
                return true
            }
        )

        #expect(outcome == .stillSettingUp(instanceID: expectedInstance))
        #expect(!recordCalled)
    }

    @Test func absentOrFailedDoesNotRecord() async {
        var recordCalled = false

        let outcomeAbsent = await verifySupportingConnection(
            expectedInstanceID: expectedInstance,
            expectedCAFingerprint: sampleFingerprint,
            heldState: .noneHeld,
            isMarkAlreadyRecorded: false,
            captureAdmission: { makeDefaultAdmission() },
            confirmAdmission: { _ in true },
            startPairing: { fatalError() },
            submit: { _ in fatalError() },
            durableInstanceID: { expectedInstance },
            resolveIdentity: { .absent },
            record: { _, _ in
                recordCalled = true
                return true
            }
        )
        #expect(outcomeAbsent == .fetchAbsent)
        #expect(!recordCalled)

        let outcomeFailed = await verifySupportingConnection(
            expectedInstanceID: expectedInstance,
            expectedCAFingerprint: sampleFingerprint,
            heldState: .noneHeld,
            isMarkAlreadyRecorded: false,
            captureAdmission: { makeDefaultAdmission() },
            confirmAdmission: { _ in true },
            startPairing: { fatalError() },
            submit: { _ in fatalError() },
            durableInstanceID: { expectedInstance },
            resolveIdentity: { .failed(.httpStatus(500)) },
            record: { _, _ in
                recordCalled = true
                return true
            }
        )
        #expect(outcomeFailed == .fetchFailed(.httpStatus(500)))
        #expect(!recordCalled)
    }

    @Test func mismatchedMarkInstanceIDDoesNotRecord() async {
        var recordCalled = false

        let outcome = await verifySupportingConnection(
            expectedInstanceID: expectedInstance,
            expectedCAFingerprint: sampleFingerprint,
            heldState: .noneHeld,
            isMarkAlreadyRecorded: false,
            captureAdmission: { makeDefaultAdmission() },
            confirmAdmission: { _ in true },
            startPairing: { fatalError() },
            submit: { _ in fatalError() },
            durableInstanceID: { expectedInstance },
            resolveIdentity: {
                .mark(JournalMark.uiTestSample, instanceID: "different-inst")
            },
            record: { _, _ in
                recordCalled = true
                return true
            }
        )

        #expect(outcome == .durableInstanceMismatch)
        #expect(!recordCalled)
    }

    @Test func recordReturningFalseYieldsRecordFailed() async {
        let outcome = await verifySupportingConnection(
            expectedInstanceID: expectedInstance,
            expectedCAFingerprint: sampleFingerprint,
            heldState: .noneHeld,
            isMarkAlreadyRecorded: false,
            captureAdmission: { makeDefaultAdmission() },
            confirmAdmission: { _ in true },
            startPairing: { fatalError() },
            submit: { _ in fatalError() },
            durableInstanceID: { expectedInstance },
            resolveIdentity: {
                .mark(JournalMark.uiTestSample, instanceID: expectedInstance)
            },
            record: { _, _ in false }
        )

        #expect(outcome == .recordFailed)
    }

    @Test func resumeWithCAMismatchReturnsFingerprintMismatchAndSkipsPairStartAndRecord() async {
        var startCalled = false
        var recordCalled = false

        let outcome = await verifySupportingConnection(
            expectedInstanceID: expectedInstance,
            expectedCAFingerprint: sampleFingerprint,
            heldState: .noneHeld,
            isMarkAlreadyRecorded: false,
            captureAdmission: {
                makeDefaultAdmission(caMatches: false)
            },
            confirmAdmission: { _ in true },
            startPairing: {
                startCalled = true
                fatalError("Should not pair-start")
            },
            submit: { _ in fatalError() },
            durableInstanceID: { expectedInstance },
            resolveIdentity: {
                .mark(JournalMark.uiTestSample, instanceID: expectedInstance)
            },
            record: { _, _ in
                recordCalled = true
                return true
            }
        )

        #expect(outcome == .fingerprintOrPinMismatch)
        #expect(!startCalled)
        #expect(!recordCalled)
    }

    @Test func resolveIdentityFlipsCredentialYieldsDurableInstanceMismatchAndDoesNotRecord() async {
        var recordCalled = false

        let outcome = await verifySupportingConnection(
            expectedInstanceID: expectedInstance,
            expectedCAFingerprint: sampleFingerprint,
            heldState: .noneHeld,
            isMarkAlreadyRecorded: false,
            captureAdmission: {
                makeDefaultAdmission()
            },
            confirmAdmission: { _ in
                // Credential flipped during fetch
                false
            },
            startPairing: { fatalError() },
            submit: { _ in fatalError() },
            durableInstanceID: { expectedInstance },
            resolveIdentity: {
                .mark(JournalMark.uiTestSample, instanceID: expectedInstance)
            },
            record: { _, _ in
                recordCalled = true
                return true
            }
        )

        #expect(outcome == .durableInstanceMismatch)
        #expect(!recordCalled)
    }

    @Test func tunnelIdentityBasePortFiltering() {
        #expect(tunnelIdentityBase(localPort: 5015) == nil)
        #expect(tunnelIdentityBase(localPort: nil) == nil)
        #expect(tunnelIdentityBase(localPort: 0) == nil)
        #expect(tunnelIdentityBase(localPort: -1) == nil)
        #expect(tunnelIdentityBase(localPort: 12345) == "http://127.0.0.1:12345")

        #expect(tunnelIdentityBase(state: .disconnected) == nil)
        #expect(tunnelIdentityBase(state: .connecting) == nil)
        #expect(tunnelIdentityBase(state: .connected(localPort: 5015, via: .lan)) == nil)
        #expect(tunnelIdentityBase(state: .connected(localPort: 12345, via: .lan)) == "http://127.0.0.1:12345")
    }
}
