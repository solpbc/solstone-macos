// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("ExcludedSitesLineage")
struct ExcludedSitesLineageTests {
    private func suite() throws -> (UserDefaults, String) {
        let name = "site-lineage-test-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func absentListStartsANewLineageAtRevisionZeroAndReloadsTheSame() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let first = AppConfig.load(from: defaults)
        #expect(first.excludedSites.isEmpty)
        #expect(!first.excludedSitesEpoch.isEmpty)
        #expect(first.excludedSitesRev == 0)
        let second = AppConfig.load(from: defaults)
        #expect(second.excludedSitesEpoch == first.excludedSitesEpoch)
        #expect(second.excludedSitesRev == 0)
    }

    @Test func plainListFromAnOlderBuildKeepsEverySiteInANewLineage() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["bank.com", "news.com"], forKey: "excludedSites")
        let loaded = AppConfig.load(from: defaults)
        #expect(loaded.excludedSites == ["bank.com", "news.com"])
        #expect(!loaded.excludedSitesEpoch.isEmpty)
        #expect(loaded.excludedSitesRev == 1)
        #expect(AppConfig.load(from: defaults).excludedSitesEpoch == loaded.excludedSitesEpoch)
    }

    @Test func savedLineageRoundTrips() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        var config = AppConfig.load(from: defaults)
        config.excludedSites = ["bank.com"]
        config.excludedSitesRev = 4
        try config.save(to: defaults)
        let loaded = AppConfig.load(from: defaults)
        #expect(loaded.excludedSites == ["bank.com"])
        #expect(loaded.excludedSitesEpoch == config.excludedSitesEpoch)
        #expect(loaded.excludedSitesRev == 4)
    }

    @Test func anOlderBuildsEditToThePlainListBecomesTheNextRevision() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        var config = AppConfig.load(from: defaults)
        config.excludedSites = ["bank.com"]
        config.excludedSitesRev = 2
        try config.save(to: defaults)
        defaults.set(["bank.com", "mail.com"], forKey: "excludedSites")
        let loaded = AppConfig.load(from: defaults)
        #expect(loaded.excludedSites == ["bank.com", "mail.com"])
        #expect(loaded.excludedSitesEpoch == config.excludedSitesEpoch)
        #expect(loaded.excludedSitesRev == 3)
        #expect(AppConfig.load(from: defaults).excludedSitesRev == 3)
    }

    @Test func unreadableLineageIsKeptAsideAndTheListSurvives() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["bank.com"], forKey: "excludedSites")
        defaults.set(Data("not json".utf8), forKey: "excludedSitesState")
        let loaded = AppConfig.load(from: defaults)
        #expect(loaded.excludedSites == ["bank.com"])
        #expect(!loaded.excludedSitesEpoch.isEmpty)
        #expect(defaults.data(forKey: "excludedSitesState.backup") == Data("not json".utf8))
        #expect(AppConfig.load(from: defaults).excludedSitesEpoch == loaded.excludedSitesEpoch)
    }

    @Test @MainActor func everyListChangeMovesTheRevisionOnAndRemovalIsByValue() {
        var config = AppConfig()
        config.excludedSites = ["bank.com", "news.com"]
        config.excludedSitesEpoch = "e1"
        config.excludedSitesRev = 5
        let state = AppState.forSnapshot(config: config)
        state.removeExcludedSite("news.com")
        #expect(state.config.excludedSites == ["bank.com"])
        #expect(state.config.excludedSitesEpoch == "e1")
        #expect(state.config.excludedSitesRev == 6)
        state.removeExcludedSite("news.com")
        #expect(state.config.excludedSitesRev == 6)
        var unrelated = state.config
        unrelated.isMicrophoneCaptureEnabled.toggle()
        state.updateConfig(unrelated)
        #expect(state.config.excludedSitesRev == 6)
    }
}

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

@Suite("BrowserSiteList")
struct BrowserSiteListTests {
    private var projection: BrowserContractProjection {
        get throws {
            try BrowserContractProjection(rootURL: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("vendor"))
        }
    }

    private func state() -> Data {
        Data(#"{"type":"state","capture":"permitted","delivery":"idle","freshness_ms":1000,"destination_generation":"g","period_id":"p","custody":{"full":false,"stale":false},"version":"1.0.0"}"#.utf8)
    }

    @Test func noListMeansNoFields() throws {
        let source = BrowserSiteListSource()
        #expect(source.decorate(state(), brand: .safari, siteRuleAck: 3, projection: try projection) == state())
    }

    @Test func stateCarriesTheListDesktopFactsAndTheLastAnsweredRule() throws {
        let source = BrowserSiteListSource()
        source.update(BrowserSiteListSnapshot(sites: ["bank.com"], epoch: "e1", rev: 7, screen: true, activity: false,
                                              accessibilityWorks: true))
        let object = try #require(try JSONSerialization.jsonObject(
            with: source.decorate(state(), brand: .safari, siteRuleAck: 3, projection: try projection)) as? [String: Any])
        #expect(object["left_out"] as? [String] == ["bank.com"])
        #expect(object["left_out_epoch"] as? String == "e1")
        #expect(object["left_out_rev"] as? Int == 7)
        #expect(object["site_rule_ack"] as? Int == 3)
        let desktop = try #require(object["desktop"] as? [String: Any])
        #expect(desktop["screen"] as? Bool == true)
        #expect(desktop["activity"] as? Bool == false)
        #expect(desktop["sites"] as? String == "on")
    }

    @Test func sitesValueSaysWhatTheAppChecksForEachBrowser() {
        var snapshot = BrowserSiteListSnapshot(sites: ["bank.com"], epoch: "e", rev: 1, accessibilityWorks: true)
        #expect(snapshot.sitesValue(for: .safari) == "on")
        #expect(snapshot.sitesValue(for: .chrome) == "not_checked")
        #expect(snapshot.sitesValue(for: nil) == "not_checked")
        snapshot.brandsWithCaution = [.safari]
        #expect(snapshot.sitesValue(for: .safari) == "needs_access")
        snapshot.brandsWithCaution = []
        snapshot.accessibilityWorks = false
        #expect(snapshot.sitesValue(for: .safari) == "needs_access")
    }

    @Test func otherMessagesPassThrough() throws {
        let source = BrowserSiteListSource()
        source.update(BrowserSiteListSnapshot(sites: ["bank.com"], epoch: "e1", rev: 1))
        let bye = Data(#"{"type":"bye","reason":"replaced"}"#.utf8)
        #expect(source.decorate(bye, brand: .chrome, siteRuleAck: nil, projection: try projection) == bye)
    }

    @Test func ruleBucketAllowsSixtyThenOnePerSecond() {
        var bucket = BrowserSiteRuleBucket(nowMs: 0)
        var taken: [Bool] = []
        for _ in 0..<60 { taken.append(bucket.take(nowMs: 0)) }
        #expect(taken.allSatisfy { $0 })
        taken = [bucket.take(nowMs: 0), bucket.take(nowMs: 500), bucket.take(nowMs: 1_000), bucket.take(nowMs: 1_000)]
        #expect(taken == [false, false, true, false])
    }

    @Test func siteRuleDecodesAndRefusals() throws {
        let p = try projection
        func decode(_ s: String) -> BrowserDecodeResult {
            BrowserPayloadDecoder.decode(bytes: Data(s.utf8), direction: "extension_to_host", projection: p)
        }
        if case .accept(.siteRule(let rule)) = decode(#"{"type":"site_rule","id":4,"host":"bank.com","out":false}"#) {
            #expect(rule == BrowserDecodedSiteRule(id: 4, host: "bank.com", out: false))
        } else { #expect(Bool(false), "valid site_rule should decode") }
        if case .refuse(let r) = decode(#"{"type":"site_rule","id":4,"host":"bank .com","out":true}"#) {
            #expect(r.code == "invalid_host")
        } else { #expect(Bool(false)) }
        if case .refuse(let r) = decode(#"{"type":"site_rule","id":0,"host":"bank.com","out":true}"#) {
            #expect(r.code == "bad_number")
        } else { #expect(Bool(false)) }
        if case .refuse(let r) = decode(#"{"type":"site_rule","id":4,"host":"bank.com","out":1}"#) {
            #expect(r.code == "bad_type")
        } else { #expect(Bool(false)) }
        #expect(BrowserPayloadDecoder.siteRuleID(in: Data(#"{"type":"site_rule","id":9,"host":"bank .com"}"#.utf8)) == 9)
        #expect(BrowserPayloadDecoder.siteRuleID(in: Data(#"{"type":"batch","id":9}"#.utf8)) == nil)
    }

    @Test func sourcesRowSaysWhenTheLastPageWasFrom() {
        var row = BrowserBrandRow(brand: .safari, connectedCount: 1, lastSeen: nil, registration: .unknown)
        #expect(browserRowStatusText(row) == UICopy.SOURCES_BROWSER_CONNECTED_NOW)
        row.lastPage = .justNow
        #expect(browserRowStatusText(row) == UICopy.sourcesBrowserConnectedLastPage(formatRelativeBucket(.justNow)))
        row.connectedCount = 0
        #expect(browserRowStatusText(row) == UICopy.sourcesBrowserLastPage(formatRelativeBucket(.justNow)))
        row.needsExtensionUpdate = true
        #expect(browserRowStatusText(row) == UICopy.SOURCES_BROWSER_NEEDS_EXT_UPDATE)
    }

    @Test func brandRowsReadLastPageTimesFromTheSnapshot() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var snapshot = BrowserHostSnapshotValue()
        snapshot.lastPageMs[.safari] = UInt64((now.timeIntervalSince1970 - 30) * 1000)
        let rows = browserBrandRows(snapshot, now: now)
        #expect(rows.first { $0.brand == .safari }?.lastPage != nil)
        #expect(rows.first { $0.brand == .chrome }?.lastPage == nil)
    }
}

#endif
