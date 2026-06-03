import Foundation
import Testing
@testable import solstone

@Suite("UpdateState", .serialized)
@MainActor
struct UpdateStateTests {
    private let validFeedURL = "https://updates.solstone.app/solstone-macos/appcast.xml"
    private let validPublicKey = "11qYAYKxCrfVS/7TyWQHOg7hcvPa9jIlrwIaaPcHUho="
    private let statusKey = "solstone.updates.status"
    private let legacyLastCheckedAtKey = "solstone.updates.lastCheckedAt"
    private let legacyLastCheckResultKey = "solstone.updates.lastCheckResult"

    @Test func activityEquality() {
        #expect(UpdateActivity.idle == .idle)
        #expect(UpdateActivity.checking != .idle)
        #expect(
            UpdateActivity.downloading(version: "1.1.0", receivedBytes: 1, totalBytes: 10)
                == .downloading(version: "1.1.0", receivedBytes: 1, totalBytes: 10)
        )
        #expect(
            UpdateActivity.extracting(version: "1.1.0", progress: 0.5)
                != .extracting(version: "1.1.0", progress: 0.6)
        )
        #expect(
            UpdateActivity.readyToInstall(version: "1.1.0", releaseNotes: "notes")
                == .readyToInstall(version: "1.1.0", releaseNotes: "notes")
        )
        #expect(UpdateActivity.installing(version: "1.1.0") != .installing(version: "1.1.1"))
    }

    @Test func modelTypesAreSendable() {
        func _acceptsSendable<T: Sendable>(_: T.Type) {}
        _acceptsSendable(AvailableUpdate.self)
        _acceptsSendable(UpdateActivity.self)
        _acceptsSendable(ReconciledUpdateStatus.self)
        _acceptsSendable(DeferredInstallIntent.self)
        #expect(Bool(true))
    }

    @Test func reconciledStatusCodableShapeUsesOnePersistedSource() throws {
        let checkedAt = Date(timeIntervalSinceReferenceDate: 1_234)
        let status = ReconciledUpdateStatus(
            availableVersion: "1.3.9",
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: checkedAt, outcome: .found)
        )

        let data = try JSONEncoder().encode(status)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let lastCheck = try #require(object["lastCheck"] as? [String: Any])

        #expect(object["availableVersion"] as? String == "1.3.9")
        #expect(lastCheck["outcome"] as? String == "found")
        #expect(lastCheck["checkedAt"] is Double)

        let decoded = try JSONDecoder().decode(ReconciledUpdateStatus.self, from: data)
        #expect(decoded == status)
    }

    @Test func migratesLegacyUpToDateResultAndDeletesLegacyKeys() {
        clearDefaults()
        defer { clearDefaults() }
        let checkedAt = Date(timeIntervalSinceReferenceDate: 10)
        UserDefaults.standard.set(checkedAt, forKey: legacyLastCheckedAtKey)
        UserDefaults.standard.set("upToDate", forKey: legacyLastCheckResultKey)

        let controller = makeController()

        #expect(controller.availableUpdate == nil)
        #expect(controller.reconciledStatus.lastCheck?.checkedAt == checkedAt)
        #expect(controller.reconciledStatus.lastCheck?.outcome == .upToDate)
        #expect(UserDefaults.standard.data(forKey: statusKey) != nil)
        #expect(UserDefaults.standard.object(forKey: legacyLastCheckedAtKey) == nil)
        #expect(UserDefaults.standard.object(forKey: legacyLastCheckResultKey) == nil)
    }

    @Test func migratesLegacyFailedResultAndDeletesLegacyKeys() {
        clearDefaults()
        defer { clearDefaults() }
        let checkedAt = Date(timeIntervalSinceReferenceDate: 20)
        UserDefaults.standard.set(checkedAt, forKey: legacyLastCheckedAtKey)
        UserDefaults.standard.set("failed", forKey: legacyLastCheckResultKey)

        let controller = makeController()

        #expect(controller.availableUpdate == nil)
        #expect(controller.reconciledStatus.lastCheck?.checkedAt == checkedAt)
        #expect(controller.reconciledStatus.lastCheck?.outcome == .failed)
        #expect(UserDefaults.standard.data(forKey: statusKey) != nil)
        #expect(UserDefaults.standard.object(forKey: legacyLastCheckedAtKey) == nil)
        #expect(UserDefaults.standard.object(forKey: legacyLastCheckResultKey) == nil)
    }

    @Test func migratesLegacyFoundResultIntoDurableAvailableVersion() {
        clearDefaults()
        defer { clearDefaults() }
        let checkedAt = Date(timeIntervalSinceReferenceDate: 30)
        UserDefaults.standard.set(checkedAt, forKey: legacyLastCheckedAtKey)
        UserDefaults.standard.set("updateFound:1.3.9", forKey: legacyLastCheckResultKey)

        let controller = makeController(runningVersion: "1.3.8")

        #expect(controller.availableUpdate?.version == "1.3.9")
        #expect(controller.availableUpdate?.releaseNotes == nil)
        #expect(controller.reconciledStatus.availableVersion == "1.3.9")
        #expect(controller.reconciledStatus.lastCheck?.checkedAt == checkedAt)
        #expect(controller.reconciledStatus.lastCheck?.outcome == .found)
        #expect(UserDefaults.standard.data(forKey: statusKey) != nil)
        #expect(UserDefaults.standard.object(forKey: legacyLastCheckedAtKey) == nil)
        #expect(UserDefaults.standard.object(forKey: legacyLastCheckResultKey) == nil)
    }

    @Test func persistedAvailableVersionEqualToRunningVersionClearsDurableFact() throws {
        clearDefaults()
        defer { clearDefaults() }
        let checkedAt = Date(timeIntervalSinceReferenceDate: 40)
        try persistStatus(
            ReconciledUpdateStatus(
                availableVersion: "1.3.9",
                lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: checkedAt, outcome: .found)
            )
        )

        let controller = makeController(runningVersion: "1.3.9")

        #expect(controller.availableUpdate == nil)
        #expect(controller.reconciledStatus.availableVersion == nil)
        #expect(controller.reconciledStatus.lastCheck?.checkedAt == checkedAt)
        #expect(controller.reconciledStatus.lastCheck?.outcome == .upToDate)
    }

    @Test func persistedAvailableVersionDifferentFromRunningVersionIsKeptByStringEquality() throws {
        clearDefaults()
        defer { clearDefaults() }
        try persistStatus(
            ReconciledUpdateStatus(
                availableVersion: "1.3.9",
                lastCheck: ReconciledUpdateStatus.LastCheck(
                    checkedAt: Date(timeIntervalSinceReferenceDate: 50),
                    outcome: .found
                )
            )
        )

        let controller = makeController(runningVersion: "1.4.0")

        #expect(controller.availableUpdate?.version == "1.3.9")
        #expect(controller.reconciledStatus.availableVersion == "1.3.9")
        #expect(controller.reconciledStatus.lastCheck?.outcome == .found)
    }

    private func makeController(runningVersion: String = "1.3.8") -> UpdateController {
        UpdateController(
            feedURL: validFeedURL,
            publicKey: validPublicKey,
            runningVersion: { runningVersion }
        ) { _, _ in
            nil
        }
    }

    private func persistStatus(_ status: ReconciledUpdateStatus) throws {
        let data = try JSONEncoder().encode(status)
        UserDefaults.standard.set(data, forKey: statusKey)
    }

    private func clearDefaults() {
        UserDefaults.standard.removeObject(forKey: statusKey)
        UserDefaults.standard.removeObject(forKey: legacyLastCheckedAtKey)
        UserDefaults.standard.removeObject(forKey: legacyLastCheckResultKey)
    }
}
