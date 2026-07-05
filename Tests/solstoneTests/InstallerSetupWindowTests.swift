import Foundation
import JournalRuntime
import Testing
import SolstoneCore
@testable import solstone

@Suite("cardState")
@MainActor
struct InstallerCardStateTests {
    @Test func mainStatesMapToCardStates() {
        let progress = SubprocessProgress(phase: "phase")

        #expect(cardState(from: .detecting) == .detecting)
        #expect(cardState(from: .awaitingChoice(existingInstall: false)) == .absent)
        #expect(cardState(from: .awaitingChoice(existingInstall: true)) == .installedPlaceholder)
        #expect(cardState(from: .cleaningUp(progress)) == .installing)
        #expect(cardState(from: .installingSolstone(progress)) == .installing)
        #expect(cardState(from: .runningSolSetup(progress)) == .installing)
        #expect(cardState(from: .verifyingIntegrity(progress)) == .installing)
        #expect(cardState(from: .registering(progress)) == .installing)
        #expect(cardState(from: .externallyManaged(solPath: "/opt/sol")) == .externallyManaged(solPath: "/opt/sol", probe: nil))
        #expect(cardState(from: .done) == .done)
        #expect(cardState(from: .failed(.installSolstone(message: "x"))) == .failed(.installSolstone(message: "x")))
    }

    @Test func terminalCardStatePreservesIntermediateWhenProbeIsNil() {
        #expect(terminalCardState(main: .done, probe: nil, failureRecord: nil) == .done)
        #expect(terminalCardState(main: .awaitingChoice(existingInstall: true), probe: nil, failureRecord: nil) == .installedPlaceholder)
    }

    @Test func terminalCardStateMapsInstalledStatesWithProbe() {
        #expect(
            terminalCardState(main: .done, probe: .current(version: "0.3.2"), failureRecord: nil)
            == .installedCurrent(version: "0.3.2")
        )
        #expect(
            terminalCardState(main: .done, probe: .outdated(installed: "0.3.1", pinned: "0.3.2"), failureRecord: nil)
            == .installing
        )
        #expect(terminalCardState(main: .done, probe: .unknown, failureRecord: nil) == .installedUnknown)
    }

    @Test func terminalCardStateMapsExternalStatesPassively() {
        let main = MainState.externallyManaged(solPath: "/opt/sol")
        #expect(terminalCardState(main: main, probe: nil, failureRecord: nil) == .externallyManaged(solPath: "/opt/sol", probe: nil))
        #expect(terminalCardState(main: main, probe: .current(version: "0.4.8"), failureRecord: nil) == .externallyManaged(solPath: "/opt/sol", probe: .current(version: "0.4.8")))
        #expect(terminalCardState(main: main, probe: .outdated(installed: "0.3.1", pinned: "0.4.8"), failureRecord: nil) == .externallyManaged(solPath: "/opt/sol", probe: .outdated(installed: "0.3.1", pinned: "0.4.8")))
        #expect(terminalCardState(main: main, probe: .unknown, failureRecord: nil) == .externallyManaged(solPath: "/opt/sol", probe: .unknown))
    }

    @Test func terminalCardStateAppliesUpgradeFailureTruthTable() {
        let progress = SubprocessProgress(phase: "phase")
        let matching = UpgradeFailureRecord(installed: "0.3.1", pinned: BundleConfig.solstonePinVersion, errorDetails: "details")
        let unknown = UpgradeFailureRecord(installed: nil, pinned: BundleConfig.solstonePinVersion, errorDetails: "details")
        let stale = UpgradeFailureRecord(installed: "0.3.1", pinned: "0.3.7", errorDetails: "details")
        let failed = MainState.failed(.installSolstone(message: "failed"))

        #expect(terminalCardState(main: failed, probe: nil, failureRecord: nil) == .failed(.installSolstone(message: "failed")))
        #expect(terminalCardState(main: failed, probe: nil, failureRecord: stale) == .failed(.installSolstone(message: "failed")))
        #expect(terminalCardState(main: failed, probe: nil, failureRecord: matching) == .upgradeFailed(installed: "0.3.1", pinned: BundleConfig.solstonePinVersion, errorDetails: "details"))
        #expect(terminalCardState(main: failed, probe: nil, failureRecord: unknown) == .upgradeFailed(installed: nil, pinned: BundleConfig.solstonePinVersion, errorDetails: "details"))
        #expect(terminalCardState(main: .done, probe: nil, failureRecord: matching) == .done)
        #expect(terminalCardState(main: .awaitingChoice(existingInstall: true), probe: nil, failureRecord: matching) == .installedPlaceholder)
        #expect(terminalCardState(main: .done, probe: .current(version: "0.3.8"), failureRecord: matching) == .installedCurrent(version: "0.3.8"))
        #expect(terminalCardState(main: .done, probe: .unknown, failureRecord: matching) == .installedUnknown)
        #expect(terminalCardState(main: .done, probe: .outdated(installed: "0.3.1", pinned: BundleConfig.solstonePinVersion), failureRecord: nil) == .installing)
        #expect(terminalCardState(main: .done, probe: .outdated(installed: "0.3.1", pinned: BundleConfig.solstonePinVersion), failureRecord: stale) == .installing)
        #expect(terminalCardState(main: .done, probe: .outdated(installed: "0.3.1", pinned: BundleConfig.solstonePinVersion), failureRecord: matching) == .upgradeFailed(installed: "0.3.1", pinned: BundleConfig.solstonePinVersion, errorDetails: "details"))
        #expect(terminalCardState(main: .installingSolstone(progress), probe: .outdated(installed: "0.3.1", pinned: BundleConfig.solstonePinVersion), failureRecord: matching) == .installing)
    }

    @Test func terminalCardStateIgnoresProbeForNonInstalledStates() {
        let progress = SubprocessProgress(phase: "phase")
        #expect(
            terminalCardState(main: .installingSolstone(progress), probe: .current(version: "0.3.2"), failureRecord: nil)
            == .installing
        )
    }
}

@Suite("service mode control compression")
struct ServiceModeControlCompressionTests {
    private static let failedCardState = InstallerCardState.failed(.registering(message: "m"))
    private static let upgradeFailedCardState = InstallerCardState.upgradeFailed(
        installed: "0.4.7",
        pinned: BundleConfig.solstonePinVersion,
        errorDetails: "details"
    )

    // This fixture list must cover every InstallerCardState case; the predicate's
    // exhaustive switch is the compile-time backstop.
    private static let allCardStateFixtures: [InstallerCardState] = [
        .detecting,
        .absent,
        .installing,
        .installedPlaceholder,
        .done,
        .installedCurrent(version: "1.0.0"),
        .installedUnknown,
        .externallyManaged(solPath: "/usr/local/bin/sol", probe: nil),
        .runtimeStarting,
        .runtimeFailed(.stopped(JournalDiagnostic(commandLabel: "journal health", outputExcerpt: "down"))),
        .runtimeUnconfirmed,
        .runtimeStoppedByUser,
        upgradeFailedCardState,
        failedCardState
    ]

    private static let bundledStatusSurfaceFixtures: [InstallerCardState] = [
        .installing,
        failedCardState,
        upgradeFailedCardState
    ]

    private static var passiveCardStateFixtures: [InstallerCardState] {
        allCardStateFixtures.filter { !bundledStatusSurfaceFixtures.contains($0) }
    }

    @Test func modeControlsNeverCompressForAnyModeOrCardState() {
        for mode in [ServiceMode.bundled, .external] {
            for cardState in Self.allCardStateFixtures {
                #expect(!shouldCompressServiceModeControls(mode: mode, cardState: cardState))
            }
        }
    }

    @Test func bundledStatusSurfaceShowsActiveAndFailedStates() {
        for cardState in Self.bundledStatusSurfaceFixtures {
            #expect(shouldShowBundledStatusSurface(cardState: cardState))
        }
    }

    @Test func bundledStatusSurfaceHidesPassiveStates() {
        for cardState in Self.passiveCardStateFixtures {
            #expect(!shouldShowBundledStatusSurface(cardState: cardState))
        }
    }
}

@Suite("rowStatus")
@MainActor
struct RowStatusTests {
    private let progress = SubprocessProgress(phase: "phase")

    @Test func detectingStateMapsRows() {
        #expect(rowStatus(for: .checkingSystem, main: .detecting, modelsProgress: .idle) == .running)
        #expect(rowStatus(for: .cleaningUp, main: .detecting, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .installSolstone, main: .detecting, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .solSetup, main: .detecting, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .verifyingIntegrity, main: .detecting, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .registering, main: .detecting, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .models, main: .detecting, modelsProgress: .idle) == .pending)
    }

    @Test func awaitingChoiceMapsRows() {
        let main = MainState.awaitingChoice(existingInstall: false)

        #expect(rowStatus(for: .checkingSystem, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .cleaningUp, main: main, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .installSolstone, main: main, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .solSetup, main: main, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .verifyingIntegrity, main: main, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .registering, main: main, modelsProgress: .idle) == .pending)
    }

    @Test func cleaningUpRowAppearsBetweenCheckingAndInstall() {
        #expect(Array(InstallerRow.allCases.prefix(3)) == [.checkingSystem, .cleaningUp, .installSolstone])
    }

    @Test func cleaningUpMapsRows() {
        let main = MainState.cleaningUp(progress)

        #expect(rowStatus(for: .checkingSystem, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .cleaningUp, main: main, modelsProgress: .idle) == .running)
        #expect(rowStatus(for: .installSolstone, main: main, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .solSetup, main: main, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .verifyingIntegrity, main: main, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .registering, main: main, modelsProgress: .idle) == .pending)
        #expect(currentSubprocessProgress(for: .cleaningUp, main: main, modelsProgress: .idle) == progress)
        #expect(currentSubprocessProgress(for: .installSolstone, main: main, modelsProgress: .idle) == nil)
    }

    @Test func installingSolstoneMapsRows() {
        let main = MainState.installingSolstone(progress)

        #expect(rowStatus(for: .checkingSystem, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .cleaningUp, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .installSolstone, main: main, modelsProgress: .idle) == .running)
        #expect(rowStatus(for: .solSetup, main: main, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .verifyingIntegrity, main: main, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .registering, main: main, modelsProgress: .idle) == .pending)
    }

    @Test func runningSolSetupMapsRows() {
        let main = MainState.runningSolSetup(progress)

        #expect(rowStatus(for: .checkingSystem, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .cleaningUp, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .installSolstone, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .solSetup, main: main, modelsProgress: .idle) == .running)
        #expect(rowStatus(for: .verifyingIntegrity, main: main, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .registering, main: main, modelsProgress: .idle) == .pending)
    }

    @Test func verifyingIntegrityMapsRowsBeforeRegistering() {
        let main = MainState.verifyingIntegrity(progress)

        #expect(rowStatus(for: .checkingSystem, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .cleaningUp, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .installSolstone, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .solSetup, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .verifyingIntegrity, main: main, modelsProgress: .idle) == .running)
        #expect(rowStatus(for: .registering, main: main, modelsProgress: .idle) == .pending)
        #expect(currentSubprocessProgress(for: .verifyingIntegrity, main: main, modelsProgress: .idle) == progress)
    }

    @Test func registeringMapsRows() {
        let main = MainState.registering(progress)

        #expect(rowStatus(for: .checkingSystem, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .cleaningUp, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .installSolstone, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .solSetup, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .verifyingIntegrity, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .registering, main: main, modelsProgress: .idle) == .running)
    }

    @Test func verifyingIntegrityWarningProjectsDuringRegistering() {
        let main = MainState.registering(progress)

        #expect(
            rowStatus(
                for: .verifyingIntegrity,
                main: main,
                modelsProgress: .idle,
                integrityWarningMessage: "couldn't get tokenizers ready; continuing"
            ) == .warning(message: "couldn't get tokenizers ready; continuing")
        )
    }

    @Test func doneMapsRows() {
        #expect(rowStatus(for: .checkingSystem, main: .done, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .cleaningUp, main: .done, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .installSolstone, main: .done, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .solSetup, main: .done, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .verifyingIntegrity, main: .done, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .registering, main: .done, modelsProgress: .idle) == .ok)
    }

    @Test func cleanupFailureShowsCleanupRowFailedAndLaterRowsPending() {
        let main = MainState.failed(.cleanup(step: .ports, message: "upgrade pre-clean failed at check ports — x"))

        #expect(rowStatus(for: .cleaningUp, main: main, modelsProgress: .idle) == .failed(message: "upgrade pre-clean failed at check ports — x"))
        #expect(rowStatus(for: .installSolstone, main: main, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .solSetup, main: main, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .verifyingIntegrity, main: main, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .registering, main: main, modelsProgress: .idle) == .pending)
    }

    @Test func installFailureMapsRows() {
        let main = MainState.failed(.installSolstone(message: "m"))

        #expect(rowStatus(for: .cleaningUp, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .installSolstone, main: main, modelsProgress: .idle) == .failed(message: "m"))
        #expect(rowStatus(for: .solSetup, main: main, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .verifyingIntegrity, main: main, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .registering, main: main, modelsProgress: .idle) == .pending)
    }

    @Test func setupFailureMapsRows() {
        let main = MainState.failed(.solSetup(errorCode: "X1", message: "m"))

        #expect(rowStatus(for: .cleaningUp, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .installSolstone, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .solSetup, main: main, modelsProgress: .idle) == .failed(message: "m"))
        #expect(rowStatus(for: .verifyingIntegrity, main: main, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .registering, main: main, modelsProgress: .idle) == .pending)
    }

    @Test func registeringFailureMapsRows() {
        let main = MainState.failed(.registering(message: "m"))

        #expect(rowStatus(for: .cleaningUp, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .installSolstone, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .solSetup, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .verifyingIntegrity, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .registering, main: main, modelsProgress: .idle) == .failed(message: "m"))
    }

    @Test func installModelsFailureMainMapsMainRows() {
        let main = MainState.failed(.installModels(message: "m"))

        #expect(rowStatus(for: .cleaningUp, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .installSolstone, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .solSetup, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .verifyingIntegrity, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .registering, main: main, modelsProgress: .idle) == .ok)
    }

    @Test func modelsProgressMapsIndependently() {
        #expect(rowStatus(for: .models, main: .detecting, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .models, main: .detecting, modelsProgress: .running(progress)) == .running)
        #expect(rowStatus(for: .models, main: .detecting, modelsProgress: .done) == .ok)
        #expect(rowStatus(for: .models, main: .detecting, modelsProgress: .failed(message: "m")) == .failed(message: "m"))
    }
}

@Suite("logDisclosure")
struct LogDisclosureStateTests {
    @Test func emptyStateDefaultsDisclosureRowsToCollapsed() {
        let state: [String: Bool] = [:]

        #expect(!isLogExpanded(for: .cleaningUp, in: state))
        #expect(!isLogExpanded(for: .installSolstone, in: state))
        #expect(!isLogExpanded(for: .solSetup, in: state))
        #expect(!isLogExpanded(for: .verifyingIntegrity, in: state))
        #expect(!isLogExpanded(for: .registering, in: state))
        #expect(!isLogExpanded(for: .models, in: state))
    }

    @Test func explicitTrueExpandsThatRow() {
        for row in [InstallerRow.cleaningUp, .installSolstone, .solSetup, .verifyingIntegrity, .registering, .models] {
            #expect(isLogExpanded(for: row, in: [row.rawValue: true]))
        }
    }

    @Test func expansionStateIsIndependentAcrossRows() {
        let state = [InstallerRow.installSolstone.rawValue: true]

        #expect(isLogExpanded(for: .installSolstone, in: state))
        #expect(!isLogExpanded(for: .solSetup, in: state))
        #expect(!isLogExpanded(for: .verifyingIntegrity, in: state))
        #expect(!isLogExpanded(for: .registering, in: state))
        #expect(!isLogExpanded(for: .models, in: state))
    }
}

@Suite("tcc")
struct TccDetectorTests {
    private let home = (NSHomeDirectory() as NSString).standardizingPath

    @Test func unrestrictedJournalPathsReturnFalse() {
        #expect(!isJournalPathTccRestricted(URL(fileURLWithPath: home + "/journal")))
        #expect(!isJournalPathTccRestricted(URL(fileURLWithPath: home + "/journal/sub")))
        #expect(!isJournalPathTccRestricted(URL(fileURLWithPath: home + "/Documents-old/x")))
        #expect(!isJournalPathTccRestricted(URL(fileURLWithPath: home + "/journal/")))
    }

    @Test func restrictedRootsReturnTrue() {
        #expect(isJournalPathTccRestricted(URL(fileURLWithPath: home + "/Documents/foo")))
        #expect(isJournalPathTccRestricted(URL(fileURLWithPath: home + "/Documents")))
        #expect(isJournalPathTccRestricted(URL(fileURLWithPath: home + "/Desktop/x")))
        #expect(isJournalPathTccRestricted(URL(fileURLWithPath: home + "/Downloads/y")))
        #expect(isJournalPathTccRestricted(URL(fileURLWithPath: "/Volumes/USB/z")))
        #expect(isJournalPathTccRestricted(URL(fileURLWithPath: home + "/Documents/")))
    }
}
