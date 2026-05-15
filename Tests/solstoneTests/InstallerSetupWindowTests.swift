import Foundation
import Testing
@testable import solstone

@Suite("cardState")
@MainActor
struct InstallerCardStateTests {
    @Test func mainStatesMapToCardStates() {
        let progress = SubprocessProgress(phase: "phase")

        #expect(cardState(from: .detecting) == .detecting)
        #expect(cardState(from: .awaitingChoice(existingInstall: false)) == .absent)
        #expect(cardState(from: .awaitingChoice(existingInstall: true)) == .installedPlaceholder)
        #expect(cardState(from: .installingSolstone(progress)) == .installing)
        #expect(cardState(from: .runningSolSetup(progress)) == .installing)
        #expect(cardState(from: .registering(progress)) == .installing)
        #expect(cardState(from: .done) == .done)
        #expect(cardState(from: .failed(.installSolstone(message: "x"))) == .failed(.installSolstone(message: "x")))
    }
}

@Suite("rowStatus")
@MainActor
struct RowStatusTests {
    private let progress = SubprocessProgress(phase: "phase")

    @Test func detectingStateMapsRows() {
        #expect(rowStatus(for: .checkingSystem, main: .detecting, modelsProgress: .idle) == .running)
        #expect(rowStatus(for: .installSolstone, main: .detecting, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .solSetup, main: .detecting, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .registering, main: .detecting, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .models, main: .detecting, modelsProgress: .idle) == .pending)
    }

    @Test func awaitingChoiceMapsRows() {
        let main = MainState.awaitingChoice(existingInstall: false)

        #expect(rowStatus(for: .checkingSystem, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .installSolstone, main: main, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .solSetup, main: main, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .registering, main: main, modelsProgress: .idle) == .pending)
    }

    @Test func installingSolstoneMapsRows() {
        let main = MainState.installingSolstone(progress)

        #expect(rowStatus(for: .checkingSystem, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .installSolstone, main: main, modelsProgress: .idle) == .running)
        #expect(rowStatus(for: .solSetup, main: main, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .registering, main: main, modelsProgress: .idle) == .pending)
    }

    @Test func runningSolSetupMapsRows() {
        let main = MainState.runningSolSetup(progress)

        #expect(rowStatus(for: .checkingSystem, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .installSolstone, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .solSetup, main: main, modelsProgress: .idle) == .running)
        #expect(rowStatus(for: .registering, main: main, modelsProgress: .idle) == .pending)
    }

    @Test func registeringMapsRows() {
        let main = MainState.registering(progress)

        #expect(rowStatus(for: .checkingSystem, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .installSolstone, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .solSetup, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .registering, main: main, modelsProgress: .idle) == .running)
    }

    @Test func doneMapsRows() {
        #expect(rowStatus(for: .checkingSystem, main: .done, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .installSolstone, main: .done, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .solSetup, main: .done, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .registering, main: .done, modelsProgress: .idle) == .ok)
    }

    @Test func installFailureMapsRows() {
        let main = MainState.failed(.installSolstone(message: "m"))

        #expect(rowStatus(for: .installSolstone, main: main, modelsProgress: .idle) == .failed(message: "m"))
        #expect(rowStatus(for: .solSetup, main: main, modelsProgress: .idle) == .pending)
        #expect(rowStatus(for: .registering, main: main, modelsProgress: .idle) == .pending)
    }

    @Test func setupFailureMapsRows() {
        let main = MainState.failed(.solSetup(errorCode: "X1", message: "m"))

        #expect(rowStatus(for: .installSolstone, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .solSetup, main: main, modelsProgress: .idle) == .failed(message: "m"))
        #expect(rowStatus(for: .registering, main: main, modelsProgress: .idle) == .pending)
    }

    @Test func registeringFailureMapsRows() {
        let main = MainState.failed(.registering(message: "m"))

        #expect(rowStatus(for: .installSolstone, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .solSetup, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .registering, main: main, modelsProgress: .idle) == .failed(message: "m"))
    }

    @Test func installModelsFailureMainMapsMainRows() {
        let main = MainState.failed(.installModels(message: "m"))

        #expect(rowStatus(for: .installSolstone, main: main, modelsProgress: .idle) == .ok)
        #expect(rowStatus(for: .solSetup, main: main, modelsProgress: .idle) == .ok)
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

        #expect(!isLogExpanded(for: .installSolstone, in: state))
        #expect(!isLogExpanded(for: .solSetup, in: state))
        #expect(!isLogExpanded(for: .registering, in: state))
        #expect(!isLogExpanded(for: .models, in: state))
    }

    @Test func explicitTrueExpandsThatRow() {
        for row in [InstallerRow.installSolstone, .solSetup, .registering, .models] {
            #expect(isLogExpanded(for: row, in: [row.rawValue: true]))
        }
    }

    @Test func expansionStateIsIndependentAcrossRows() {
        let state = [InstallerRow.installSolstone.rawValue: true]

        #expect(isLogExpanded(for: .installSolstone, in: state))
        #expect(!isLogExpanded(for: .solSetup, in: state))
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
