import Testing
@testable import solstone

@Suite("UpdateState")
struct UpdateStateTests {
    @Test func idleEquality() {
        let a = UpdateState.idle
        let b = UpdateState.idle
        let c = UpdateState.checking
        #expect(a == b)
        #expect(a != c)
    }

    @Test func checkingEquality() {
        let a = UpdateState.checking
        let b = UpdateState.checking
        let c = UpdateState.idle
        #expect(a == b)
        #expect(a != c)
    }

    @Test func updateAvailableEquality() {
        let a = UpdateState.updateAvailable(version: "1.1.0", releaseNotes: "notes")
        let b = UpdateState.updateAvailable(version: "1.1.0", releaseNotes: "notes")
        let c = UpdateState.updateAvailable(version: "1.1.1", releaseNotes: "notes")
        #expect(a == b)
        #expect(a != c)
    }

    @Test func downloadingEquality() {
        let a = UpdateState.downloading(version: "1.1.0", receivedBytes: 1, totalBytes: 10)
        let b = UpdateState.downloading(version: "1.1.0", receivedBytes: 1, totalBytes: 10)
        let c = UpdateState.downloading(version: "1.1.0", receivedBytes: 2, totalBytes: 10)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func extractingEquality() {
        let a = UpdateState.extracting(version: "1.1.0", progress: 0.5)
        let b = UpdateState.extracting(version: "1.1.0", progress: 0.5)
        let c = UpdateState.extracting(version: "1.1.0", progress: 0.6)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func readyToInstallEquality() {
        let a = UpdateState.readyToInstall(version: "1.1.0", releaseNotes: "notes")
        let b = UpdateState.readyToInstall(version: "1.1.0", releaseNotes: "notes")
        let c = UpdateState.readyToInstall(version: "1.1.1", releaseNotes: "notes")
        #expect(a == b)
        #expect(a != c)
    }

    @Test func installingEquality() {
        let a = UpdateState.installing(version: "1.1.0")
        let b = UpdateState.installing(version: "1.1.0")
        let c = UpdateState.installing(version: "1.1.1")
        #expect(a == b)
        #expect(a != c)
    }

    @Test func noUpdateAvailableEquality() {
        let a = UpdateState.noUpdateAvailable
        let b = UpdateState.noUpdateAvailable
        let c = UpdateState.error(message: "error")
        #expect(a == b)
        #expect(a != c)
    }

    @Test func errorEquality() {
        let a = UpdateState.error(message: "error")
        let b = UpdateState.error(message: "error")
        let c = UpdateState.error(message: "different")
        #expect(a == b)
        #expect(a != c)
    }

    @Test func updateStateIsSendable() {
        func _acceptsSendable<T: Sendable>(_: T.Type) {}
        _acceptsSendable(UpdateState.self)
        #expect(Bool(true))
    }
}
