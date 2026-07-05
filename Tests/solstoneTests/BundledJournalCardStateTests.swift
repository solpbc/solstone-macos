import Foundation
import JournalRuntime
import Testing
import SolstoneCore
@testable import solstone

@Suite("bundledJournalCardState")
@MainActor
struct BundledJournalCardStateTests {
    private let stoppedDiagnostic = JournalDiagnostic(commandLabel: "journal health", outputExcerpt: "down")
    private let unknownDiagnostic = JournalDiagnostic(commandLabel: "journal readiness", outputExcerpt: "timeout")

    @Test func ac9ReachableMatrix() {
        let cases: [AC9Case] = [
            AC9Case(
                name: "unobserved-unconfirmed-idle",
                runtimeStatus: .unobserved,
                startInFlight: false,
                confirmedAtPin: false,
                expectedCardState: .runtimeUnconfirmed,
                serviceNeedsAttention: false,
                serviceIsDone: false,
                available: true
            ),
            AC9Case(
                name: "unobserved-starting",
                runtimeStatus: .unobserved,
                startInFlight: true,
                confirmedAtPin: false,
                expectedCardState: .runtimeStarting,
                serviceNeedsAttention: false,
                serviceIsDone: false,
                available: true
            ),
            AC9Case(
                name: "running-unconfirmed-idle",
                runtimeStatus: .running,
                startInFlight: false,
                confirmedAtPin: false,
                expectedCardState: .runtimeUnconfirmed,
                serviceNeedsAttention: false,
                serviceIsDone: false,
                available: true
            ),
            AC9Case(
                name: "running-confirmed-idle",
                runtimeStatus: .running,
                startInFlight: false,
                confirmedAtPin: true,
                expectedCardState: .installedCurrent(version: BundleConfig.solstonePinVersion),
                serviceNeedsAttention: false,
                serviceIsDone: true,
                available: true
            ),
            AC9Case(
                name: "running-unconfirmed-starting",
                runtimeStatus: .running,
                startInFlight: true,
                confirmedAtPin: false,
                expectedCardState: .runtimeStarting,
                serviceNeedsAttention: false,
                serviceIsDone: false,
                available: true
            ),
            AC9Case(
                name: "running-confirmed-starting",
                runtimeStatus: .running,
                startInFlight: true,
                confirmedAtPin: true,
                expectedCardState: .runtimeStarting,
                serviceNeedsAttention: false,
                serviceIsDone: false,
                available: true
            ),
            AC9Case(
                name: "restarting-idle",
                runtimeStatus: .restarting,
                startInFlight: false,
                confirmedAtPin: false,
                expectedCardState: .runtimeStarting,
                serviceNeedsAttention: false,
                serviceIsDone: false,
                available: true
            ),
            AC9Case(
                name: "restarting-starting",
                runtimeStatus: .restarting,
                startInFlight: true,
                confirmedAtPin: false,
                expectedCardState: .runtimeStarting,
                serviceNeedsAttention: false,
                serviceIsDone: false,
                available: true
            ),
            AC9Case(
                name: "stopped-idle",
                runtimeStatus: .stopped(stoppedDiagnostic),
                startInFlight: false,
                confirmedAtPin: false,
                expectedCardState: .runtimeFailed(.stopped(stoppedDiagnostic)),
                serviceNeedsAttention: true,
                serviceIsDone: false,
                available: true
            ),
            AC9Case(
                name: "stopped-starting",
                runtimeStatus: .stopped(stoppedDiagnostic),
                startInFlight: true,
                confirmedAtPin: false,
                expectedCardState: .runtimeStarting,
                serviceNeedsAttention: false,
                serviceIsDone: false,
                available: true
            ),
            AC9Case(
                name: "unknown-idle",
                runtimeStatus: .unknown(unknownDiagnostic),
                startInFlight: false,
                confirmedAtPin: false,
                expectedCardState: .runtimeFailed(.unknown(unknownDiagnostic)),
                serviceNeedsAttention: true,
                serviceIsDone: false,
                available: true
            ),
            AC9Case(
                name: "unknown-starting",
                runtimeStatus: .unknown(unknownDiagnostic),
                startInFlight: true,
                confirmedAtPin: false,
                expectedCardState: .runtimeStarting,
                serviceNeedsAttention: false,
                serviceIsDone: false,
                available: true
            ),
            AC9Case(
                name: "setup-needed-idle",
                runtimeStatus: .setupNeeded,
                startInFlight: false,
                confirmedAtPin: false,
                expectedCardState: .runtimeFailed(.setupNeeded),
                serviceNeedsAttention: true,
                serviceIsDone: false,
                available: true
            ),
            AC9Case(
                name: "setup-needed-starting",
                runtimeStatus: .setupNeeded,
                startInFlight: true,
                confirmedAtPin: false,
                expectedCardState: .runtimeStarting,
                serviceNeedsAttention: false,
                serviceIsDone: false,
                available: true
            ),
            AC9Case(
                name: "stopped-by-user-idle",
                runtimeStatus: .stoppedByUser,
                startInFlight: false,
                confirmedAtPin: false,
                expectedCardState: .runtimeStoppedByUser,
                serviceNeedsAttention: false,
                serviceIsDone: true,
                available: true
            ),
            AC9Case(
                name: "stopped-by-user-starting",
                runtimeStatus: .stoppedByUser,
                startInFlight: true,
                confirmedAtPin: false,
                expectedCardState: .runtimeStarting,
                serviceNeedsAttention: false,
                serviceIsDone: false,
                available: true
            ),
        ]

        for testCase in cases {
            let state = bundledJournalCardState(
                main: .done,
                failureRecord: nil,
                runtimeStatus: testCase.runtimeStatus,
                startInFlight: testCase.startInFlight,
                confirmedAtPin: testCase.confirmedAtPin
            )

            #expect(state == testCase.expectedCardState, "card state failed case: \(testCase.name)")
            #expect(serviceNeedsAttention(for: state) == testCase.serviceNeedsAttention, "attention failed case: \(testCase.name)")
            #expect(serviceIsDone(for: state) == testCase.serviceIsDone, "done failed case: \(testCase.name)")
            #expect(isInstalledJournalCardState(state) == testCase.available, "availability failed case: \(testCase.name)")
        }
    }

    @Test func nonInstalledBranchesPreserveInstallerSurface() {
        let progress = SubprocessProgress(phase: "phase")
        let matchingRecord = UpgradeFailureRecord(
            installed: "0.3.1",
            pinned: BundleConfig.solstonePinVersion,
            errorDetails: "details"
        )
        let staleRecord = UpgradeFailureRecord(
            installed: "0.3.1",
            pinned: "0.3.7",
            errorDetails: "details"
        )

        #expect(makeBundledState(main: .detecting) == .detecting)
        #expect(makeBundledState(main: .awaitingChoice(existingInstall: false)) == .absent)
        #expect(makeBundledState(main: .cleaningUp(progress)) == .installing)
        #expect(makeBundledState(main: .installingSolstone(progress)) == .installing)
        #expect(makeBundledState(main: .runningSolSetup(progress)) == .installing)
        #expect(makeBundledState(main: .verifyingIntegrity(progress)) == .installing)
        #expect(makeBundledState(main: .registering(progress)) == .installing)
        #expect(makeBundledState(main: .externallyManaged(solPath: "/opt/sol")) == .externallyManaged(solPath: "/opt/sol", probe: nil))
        #expect(
            makeBundledState(
                main: .failed(.installSolstone(message: "failed")),
                failureRecord: matchingRecord
            ) == .upgradeFailed(
                installed: "0.3.1",
                pinned: BundleConfig.solstonePinVersion,
                errorDetails: "details"
            )
        )
        #expect(
            makeBundledState(
                main: .failed(.installSolstone(message: "failed")),
                failureRecord: staleRecord
            ) == .failed(.installSolstone(message: "failed"))
        )
        #expect(
            makeBundledState(
                main: .failed(.installSolstone(message: "failed")),
                failureRecord: nil
            ) == .failed(.installSolstone(message: "failed"))
        )
    }

    @Test func bundledInstalledBranchIgnoresVersionProbeShape() {
        let state = bundledJournalCardState(
            main: .done,
            failureRecord: nil,
            runtimeStatus: .running,
            startInFlight: false,
            confirmedAtPin: true
        )

        #expect(state == .installedCurrent(version: BundleConfig.solstonePinVersion))
    }

    private func makeBundledState(
        main: MainState,
        failureRecord: UpgradeFailureRecord? = nil
    ) -> InstallerCardState {
        bundledJournalCardState(
            main: main,
            failureRecord: failureRecord,
            runtimeStatus: .unobserved,
            startInFlight: false,
            confirmedAtPin: false
        )
    }

    private func serviceNeedsAttention(for state: InstallerCardState) -> Bool {
        switch state {
        case .absent, .failed, .upgradeFailed, .runtimeFailed:
            return true
        case .detecting,
             .installing,
             .installedPlaceholder,
             .done,
             .installedCurrent,
             .installedUnknown,
             .externallyManaged,
             .runtimeStarting,
             .runtimeUnconfirmed,
             .runtimeStoppedByUser:
            return false
        }
    }

    private func serviceIsDone(for state: InstallerCardState) -> Bool {
        switch state {
        case .installedCurrent, .done, .externallyManaged, .runtimeStoppedByUser:
            return true
        case .detecting,
             .absent,
             .installing,
             .installedPlaceholder,
             .installedUnknown,
             .upgradeFailed,
             .failed,
             .runtimeStarting,
             .runtimeFailed,
             .runtimeUnconfirmed:
            return false
        }
    }

    private func isInstalledJournalCardState(_ state: InstallerCardState) -> Bool {
        switch state {
        case .installedPlaceholder,
             .done,
             .installedCurrent,
             .installedUnknown,
             .runtimeStarting,
             .runtimeFailed,
             .runtimeUnconfirmed,
             .runtimeStoppedByUser:
            return true
        case .detecting,
             .absent,
             .installing,
             .externallyManaged,
             .upgradeFailed,
             .failed:
            return false
        }
    }

    private struct AC9Case {
        let name: String
        let runtimeStatus: JournalRuntimeStatus
        let startInFlight: Bool
        let confirmedAtPin: Bool
        let expectedCardState: InstallerCardState
        let serviceNeedsAttention: Bool
        let serviceIsDone: Bool
        let available: Bool
    }
}
