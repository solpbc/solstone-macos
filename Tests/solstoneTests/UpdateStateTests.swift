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
    private let isolatedDefaults = IsolatedUserDefaults()

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
        _acceptsSendable(BackgroundDownloadPhase.self)
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

    @Test func reconciledStatusCodableShapeRoundTripsStagedOutcome() throws {
        let checkedAt = Date(timeIntervalSinceReferenceDate: 2_468)
        let status = ReconciledUpdateStatus(
            availableVersion: "1.3.9",
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: checkedAt, outcome: .staged)
        )

        let data = try JSONEncoder().encode(status)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let lastCheck = try #require(object["lastCheck"] as? [String: Any])

        #expect(object["availableVersion"] as? String == "1.3.9")
        #expect(lastCheck["outcome"] as? String == "staged")
        #expect(try JSONDecoder().decode(ReconciledUpdateStatus.self, from: data) == status)
    }

    @Test func migratesLegacyUpToDateResultAndDeletesLegacyKeys() {
        clearDefaults()
        defer { clearDefaults() }
        let checkedAt = Date(timeIntervalSinceReferenceDate: 10)
        isolatedDefaults.defaults.set(checkedAt, forKey: legacyLastCheckedAtKey)
        isolatedDefaults.defaults.set("upToDate", forKey: legacyLastCheckResultKey)

        let controller = makeController()

        #expect(controller.availableUpdate == nil)
        #expect(controller.reconciledStatus.lastCheck?.checkedAt == checkedAt)
        #expect(controller.reconciledStatus.lastCheck?.outcome == .upToDate)
        #expect(isolatedDefaults.defaults.data(forKey: statusKey) != nil)
        #expect(isolatedDefaults.defaults.object(forKey: legacyLastCheckedAtKey) == nil)
        #expect(isolatedDefaults.defaults.object(forKey: legacyLastCheckResultKey) == nil)
    }

    @Test func migratesLegacyFailedResultAndDeletesLegacyKeys() {
        clearDefaults()
        defer { clearDefaults() }
        let checkedAt = Date(timeIntervalSinceReferenceDate: 20)
        isolatedDefaults.defaults.set(checkedAt, forKey: legacyLastCheckedAtKey)
        isolatedDefaults.defaults.set("failed", forKey: legacyLastCheckResultKey)

        let controller = makeController()

        #expect(controller.availableUpdate == nil)
        #expect(controller.reconciledStatus.lastCheck?.checkedAt == checkedAt)
        #expect(controller.reconciledStatus.lastCheck?.outcome == .failed)
        #expect(isolatedDefaults.defaults.data(forKey: statusKey) != nil)
        #expect(isolatedDefaults.defaults.object(forKey: legacyLastCheckedAtKey) == nil)
        #expect(isolatedDefaults.defaults.object(forKey: legacyLastCheckResultKey) == nil)
    }

    @Test func migratesLegacyFoundResultIntoDurableAvailableVersion() {
        clearDefaults()
        defer { clearDefaults() }
        let checkedAt = Date(timeIntervalSinceReferenceDate: 30)
        isolatedDefaults.defaults.set(checkedAt, forKey: legacyLastCheckedAtKey)
        isolatedDefaults.defaults.set("updateFound:1.3.9", forKey: legacyLastCheckResultKey)

        let controller = makeController(runningVersion: "1.3.8")

        #expect(controller.availableUpdate?.version == "1.3.9")
        #expect(controller.availableUpdate?.releaseNotes == nil)
        #expect(controller.reconciledStatus.availableVersion == "1.3.9")
        #expect(controller.reconciledStatus.lastCheck?.checkedAt == checkedAt)
        #expect(controller.reconciledStatus.lastCheck?.outcome == .found)
        #expect(isolatedDefaults.defaults.data(forKey: statusKey) != nil)
        #expect(isolatedDefaults.defaults.object(forKey: legacyLastCheckedAtKey) == nil)
        #expect(isolatedDefaults.defaults.object(forKey: legacyLastCheckResultKey) == nil)
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

    @Test func persistedStagedVersionDifferentFromRunningVersionIsRestored() throws {
        clearDefaults()
        defer { clearDefaults() }
        try persistStatus(
            ReconciledUpdateStatus(
                availableVersion: "1.3.9",
                lastCheck: ReconciledUpdateStatus.LastCheck(
                    checkedAt: Date(timeIntervalSinceReferenceDate: 60),
                    outcome: .staged
                )
            )
        )

        let controller = makeController(runningVersion: "1.4.0")

        #expect(controller.availableUpdate?.version == "1.3.9")
        #expect(controller.reconciledStatus.availableVersion == "1.3.9")
        #expect(controller.reconciledStatus.lastCheck?.outcome == .staged)
        #expect(controller.updateIsStaged)
    }

    private func makeController(runningVersion: String = "1.3.8") -> UpdateController {
        UpdateController(
            feedURL: validFeedURL,
            publicKey: validPublicKey,
            runningVersion: { runningVersion },
            defaults: isolatedDefaults.defaults
        ) { _, _ in
            nil
        }
    }

    private func persistStatus(_ status: ReconciledUpdateStatus) throws {
        let data = try JSONEncoder().encode(status)
        isolatedDefaults.defaults.set(data, forKey: statusKey)
    }

    private func clearDefaults() {
        isolatedDefaults.clear()
    }
}
