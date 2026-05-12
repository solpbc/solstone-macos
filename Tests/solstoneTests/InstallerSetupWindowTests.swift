import AppKit
import Foundation
import Testing
@testable import solstone

@Suite("InstallerCopyTests")
struct InstallerCopyTests {
    @Test func constantsAreLocked() {
        #expect(InstallerCopy.windowTitle == "set up solstone")
        #expect(InstallerCopy.pitch == "solstone is two halves: the journal and observer. this app is the observer. install the other half locally, or point it at an existing service.")
        #expect(InstallerCopy.installButton == "install solstone for me")
        #expect(InstallerCopy.existingButton == "i already have solstone elsewhere")
        #expect(InstallerCopy.learnMore == "learn more →")
        #expect(InstallerCopy.learnMoreURL == "https://solstone.app/install")
        #expect(InstallerCopy.state1Label == "checking your system")
        #expect(InstallerCopy.state2Label == "installing solstone")
        #expect(InstallerCopy.state3Label == "setting up your journal")
        #expect(InstallerCopy.state3aLabel == "downloading the transcription model (this can take a few minutes)")
        #expect(InstallerCopy.state4Label == "registering this observer")
        #expect(InstallerCopy.stepOk == "done")
        #expect(InstallerCopy.stepFailedPrefix == "couldn't finish — ")
        #expect(InstallerCopy.retryButton == "try again")
        #expect(InstallerCopy.showLogLabel == "show details")
        #expect(InstallerCopy.hideLogLabel == "hide details")
        #expect(InstallerCopy.journalLocationLabel == "journal location")
        #expect(InstallerCopy.journalChangeLink == "change...")
        #expect(InstallerCopy.journalPickerTitle == "choose journal location")
        #expect(InstallerCopy.journalTccWarning == "macos may ask permission to write here.")
        #expect(InstallerCopy.doneTitle == "you're all set")
        #expect(InstallerCopy.doneBody == "solstone is running on this mac. we opened the setup page in your browser — finish there to choose a password and connect your gemini key.")
        #expect(InstallerCopy.donePermissions == "next you'll be asked for screen recording, microphone, and system audio access.")
    }
}

@Suite("InstallerSetupWindowTests")
@MainActor
struct InstallerCardStateTests {
    @Test func mainStatesMapToCardStates() {
        let progress = SubprocessProgress(phase: "phase")

        #expect(cardState(from: .detecting) == .progress)
        #expect(cardState(from: .awaitingChoice(existingInstall: false)) == .choice(existingInstall: false))
        #expect(cardState(from: .awaitingChoice(existingInstall: true)) == .choice(existingInstall: true))
        #expect(cardState(from: .installingSolstone(progress)) == .progress)
        #expect(cardState(from: .runningSolSetup(progress)) == .progress)
        #expect(cardState(from: .registering(progress)) == .progress)
        #expect(cardState(from: .done) == .completion)
        #expect(cardState(from: .failed(.installSolstone(message: "x"))) == .failure(.installSolstone(message: "x")))
    }
}

@Suite("RowStatusTests")
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

@Suite("LogDisclosureStateTests")
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

@Suite("TccDetectorTests")
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

@Suite("ActivatorTests")
@MainActor
struct ActivatorTests {
    @Test func changeJournalPathActivatesAndConfiguresPanel() {
        let fakeActivator = FakeActivator()
        let installer = SolstoneInstaller()
        let expectedURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("journal-next")
        let window = InstallerSetupWindow(
            installer: installer,
            activator: fakeActivator,
            onInstall: { _, _ in },
            onExisting: { },
            onRetry: { },
            onDismiss: { }
        )

        window.changeJournalPath { panel in
            #expect(!panel.canChooseFiles)
            #expect(panel.canChooseDirectories)
            #expect(!panel.allowsMultipleSelection)
            #expect(panel.canCreateDirectories)
            #expect(panel.directoryURL?.standardizedFileURL.path == URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path)
            return expectedURL
        }

        #expect(fakeActivator.calls == 1)
    }
}

@MainActor
private final class FakeActivator: AppActivator {
    var calls = 0

    func activate() {
        calls += 1
    }
}
