// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Foundation
import os

/// What the app tells each browser extension about its left-out website list and about
/// what still goes into the journal from this mac. The app owns the list; the extension
/// follows it. One shared, always-current snapshot: every state a session sends reads it
/// at send time, so no session ever sees an older list revision after a newer one.
public struct BrowserSiteListSnapshot: Sendable, Equatable {
    public var sites: [String]
    public var epoch: String
    public var rev: Int
    /// Screen intake is running and not paused.
    public var screen: Bool
    /// The desktop activity source is running and not paused.
    public var activity: Bool
    /// Browsers whose windows the website rule checks on screen (Safari today).
    public var checkedBrands: Set<BrowserBrand>
    /// The latest Accessibility sample works.
    public var accessibilityWorks: Bool
    /// Browsers whose page addresses currently can't be read.
    public var brandsWithCaution: Set<BrowserBrand>

    public init(sites: [String] = [], epoch: String = "", rev: Int = 0, screen: Bool = false, activity: Bool = false,
                checkedBrands: Set<BrowserBrand> = [.safari], accessibilityWorks: Bool = false,
                brandsWithCaution: Set<BrowserBrand> = []) {
        self.sites = sites
        self.epoch = epoch
        self.rev = rev
        self.screen = screen
        self.activity = activity
        self.checkedBrands = checkedBrands
        self.accessibilityWorks = accessibilityWorks
        self.brandsWithCaution = brandsWithCaution
    }

    /// Whether the app keeps a left-out site off the screen for this browser.
    public func sitesValue(for brand: BrowserBrand?) -> String {
        guard let brand, checkedBrands.contains(brand) else { return "not_checked" }
        return accessibilityWorks && !brandsWithCaution.contains(brand) ? "on" : "needs_access"
    }
}

public final class BrowserSiteListSource: Sendable {
    private let state = OSAllocatedUnfairLock<BrowserSiteListSnapshot?>(initialState: nil)

    public init() {}

    /// Nil until the app has published its list; a host with no list sends none of these fields.
    public var current: BrowserSiteListSnapshot? { state.withLock { $0 } }

    /// Returns whether anything changed.
    @discardableResult
    public func update(_ snapshot: BrowserSiteListSnapshot) -> Bool {
        state.withLock { current in
            guard current != snapshot else { return false }
            current = snapshot
            return true
        }
    }

    /// Adds the site-list fields to a host `state` or `hello_ack`. Anything else passes through.
    /// The result is validated against the contract; if the full form doesn't validate (size),
    /// the `about` block is dropped; if that still fails, the message goes out as it came.
    public func decorate(_ data: Data, brand: BrowserBrand?, siteRuleAck: Int?,
                         projection: BrowserContractProjection) -> Data {
        guard let snapshot = current,
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String, type == "state" || type == "hello_ack" else { return data }
        // The extension checks every frame against the contract's bounds and drops the
        // connection on any breach, so only what the contract allows goes out. The app's
        // own rules still use the whole list.
        guard Self.isWireEpoch(snapshot.epoch) else { return data }
        object["left_out"] = Self.wireSites(snapshot.sites)
        object["left_out_epoch"] = snapshot.epoch
        object["left_out_rev"] = max(0, snapshot.rev)
        object["desktop"] = [
            "screen": snapshot.screen,
            "activity": snapshot.activity,
            "sites": snapshot.sitesValue(for: brand),
        ] as [String: Any]
        if let siteRuleAck { object["site_rule_ack"] = siteRuleAck }
        if let message = try? BrowserPayloadDecoder.validatedHostMessage(object, projection: projection) {
            return BrowserPayloadDecoder.encodeHostToExtension(message)
        }
        object.removeValue(forKey: "about")
        if let message = try? BrowserPayloadDecoder.validatedHostMessage(object, projection: projection) {
            return BrowserPayloadDecoder.encodeHostToExtension(message)
        }
        return data
    }
}

extension BrowserSiteListSource {
    static let wireSiteLimit = 200
    private static let hostPattern = #"^(\[[0-9a-fA-F:.]+\]|(?:\d{1,3}\.){3}\d{1,3}|[a-z0-9_-]+(?:\.[a-z0-9_-]+)*)$"#

    /// A host the contract's `left_out` items accept: 1..253 characters in the host grammar.
    static func isWireHost(_ host: String) -> Bool {
        (1...253).contains(host.utf8.count) && host.range(of: hostPattern, options: .regularExpression) != nil
    }

    static func wireSites(_ sites: [String]) -> [String] {
        Array(sites.filter(isWireHost).prefix(wireSiteLimit))
    }

    static func isWireEpoch(_ epoch: String) -> Bool {
        (1...64).contains(epoch.utf8.count)
    }
}

/// A per-session token bucket: 60 rules, refilled at one per second.
struct BrowserSiteRuleBucket {
    private var tokens: Double = 60
    private var last: UInt64

    init(nowMs: UInt64) { last = nowMs }

    mutating func take(nowMs: UInt64) -> Bool {
        let elapsed = Double(nowMs &- last) / 1000
        last = nowMs
        tokens = min(60, tokens + elapsed)
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

#endif
