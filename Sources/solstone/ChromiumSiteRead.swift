// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation

public struct ChromiumActivityWindowSnapshot: Sendable, Equatable {
    public let verdict: ChromiumVerdict
    public let host: String?
    public let start: TimeInterval
    public let listGeneration: UInt64

    public init(verdict: ChromiumVerdict, host: String?, start: TimeInterval, listGeneration: UInt64) {
        self.verdict = verdict
        self.host = host
        self.start = start
        self.listGeneration = listGeneration
    }
}

public struct ChromiumActivitySnapshot: Sendable, Equatable {
    public var currentGeneration: UInt64 = 0
    public var latestCGTitle: [CGWindowID: String] = [:]
    public var latestAXTitle: [CGWindowID: String] = [:]
    public var latestCompleteRead: [CGWindowID: ChromiumActivityWindowSnapshot] = [:]

    public init(currentGeneration: UInt64 = 0) {
        self.currentGeneration = currentGeneration
    }
}

public enum ChromiumVerdict: String, Sendable, Equatable {
    case covered
    case ordinary
    case cantTell
}

public enum ChromiumUnclearCause: String, Sendable, Equatable {
    case unread
    case unclear
}

public struct ChromiumPassResult: Sendable, Equatable {
    public let axTitle: String
    public let docHash: Int
    public let host: String?
    public let time: TimeInterval
    public let selectedTabCount: Int
    public let totalTabCount: Int

    public init(
        axTitle: String,
        docHash: Int,
        host: String?,
        time: TimeInterval,
        selectedTabCount: Int,
        totalTabCount: Int
    ) {
        self.axTitle = axTitle
        self.docHash = docHash
        self.host = host
        self.time = time
        self.selectedTabCount = selectedTabCount
        self.totalTabCount = totalTabCount
    }
}

public enum ChromiumTabStripOutcome: Sendable, Equatable {
    case notRun
    case truncated
    case failed
    case counts(selected: Int, total: Int)
}

public struct ChromiumRule6Record: Sendable, Equatable {
    public var waitStart: TimeInterval
    public var host: String

    public init(waitStart: TimeInterval, host: String) {
        self.waitStart = waitStart
        self.host = host
    }
}

public struct ChromiumPageEvaluation: Sendable, Equatable {
    public let verdict: ChromiumVerdict
    public let cause: ChromiumUnclearCause?
    public let host: String?

    public init(verdict: ChromiumVerdict, cause: ChromiumUnclearCause?, host: String?) {
        self.verdict = verdict
        self.cause = cause
        self.host = host
    }
}

public enum ChromiumSiteRead {
    public static func documentIdentityHash(doc: String, axTitle: String) -> Int {
        var hasher = Hasher()
        hasher.combine(doc)
        hasher.combine(axTitle)
        return hasher.finalize()
    }

    public static func brandTail(for browser: PrivateBrowser) -> String? {
        switch browser {
        case .chrome: return " - Google Chrome"
        case .edge: return " - Microsoft Edge"
        case .brave: return " - Brave"
        default: return nil
        }
    }

    public static func brandName(for browser: PrivateBrowser) -> String? {
        switch browser {
        case .chrome: return "Google Chrome"
        case .edge: return "Microsoft Edge"
        case .brave: return "Brave"
        default: return nil
        }
    }

    public enum TitleCheckResult: Equatable {
        case appWindow
        case plain
        case inserted
        case failed
    }

    public static func checkTitles(
        cgTitle: String,
        axTitle: String,
        browser: PrivateBrowser,
        tabButtonCount: Int?
    ) -> TitleCheckResult {
        guard let brand = brandName(for: browser) else { return .failed }

        if axTitle == cgTitle {
            return tabButtonCount == 0 ? .appWindow : .failed
        }

        if cgTitle.isEmpty || cgTitle.hasPrefix(" - ") {
            return .failed
        }

        guard axTitle.hasPrefix(cgTitle) else { return .failed }
        let rest = String(axTitle.dropFirst(cgTitle.count))
        guard rest.hasPrefix(" - ") else { return .failed }

        let brandTail = " - " + brand
        guard rest.contains(brandTail) else { return .failed }

        let afterFirstDash = String(rest.dropFirst(3))

        if afterFirstDash == brand {
            return .plain
        }

        let parenPrefix = brand + " ("
        if afterFirstDash.hasPrefix(parenPrefix) && afterFirstDash.hasSuffix(")") {
            return .plain
        }

        let profilePrefix = brand + " - "
        if afterFirstDash.hasPrefix(profilePrefix) {
            let profileName = afterFirstDash.dropFirst(profilePrefix.count)
            if !profileName.isEmpty && !profileName.contains(" - ") {
                return .plain
            }
        }

        return .inserted
    }

    public enum DocumentClassification {
        case covered(host: String)
        case ordinaryNonHttp
        case ordinaryHttp(host: String)
        case cantTell(ChromiumUnclearCause)
    }

    public static func classifyDocument(
        doc: String?,
        readFailed: Bool,
        sites: [String]
    ) -> DocumentClassification {
        if readFailed || doc == nil {
            return .cantTell(.unread)
        }
        guard let doc else { return .cantTell(.unread) }

        if doc.isEmpty {
            return .cantTell(.unclear) // empty doc handled with titles in evaluatePageWindow
        }

        // Unwrap filesystem:, blob:, and view-source: through SiteRule.normalizeReadHost
        // before any bare file: / data: / about: / chrome: bucket.
        if doc.hasPrefix("filesystem:") || doc.hasPrefix("blob:") || doc.hasPrefix("view-source:") {
            guard let host = SiteRule.normalizeReadHost(doc) else {
                return .cantTell(.unclear)
            }
            if sites.contains(where: { SiteRule.covers(siteHost: $0, host: host) }) {
                return .covered(host: host)
            }
            return .ordinaryHttp(host: host)
        }

        // about:blank and about:srcdoc with or without query/fragment are cantTell
        if doc.hasPrefix("about:blank") || doc.hasPrefix("about:srcdoc") {
            return .cantTell(.unclear)
        }

        // Schemes that are inherently ordinary without host checking
        let nonHttpOrdinarySchemes = [
            "file:", "data:", "about:", "chrome:", "edge:", "brave:", "chrome-extension:"
        ]
        for s in nonHttpOrdinarySchemes {
            if doc.hasPrefix(s) {
                return .ordinaryNonHttp
            }
        }

        let nonHttpCantTellSchemes = [
            "chrome-error:", "chrome-untrusted:", "ftp:"
        ]
        for s in nonHttpCantTellSchemes {
            if doc.hasPrefix(s) {
                return .cantTell(.unclear)
            }
        }

        guard let host = SiteRule.normalizeReadHost(doc) else {
            return .cantTell(.unclear)
        }

        if sites.contains(where: { SiteRule.covers(siteHost: $0, host: host) }) {
            return .covered(host: host)
        }

        return .ordinaryHttp(host: host)
    }

    /// Pure function evaluating one Chromium page window (with inout rule 6 record).
    public static func evaluatePageWindow(
        windowID: CGWindowID,
        browser: PrivateBrowser,
        cgTitle: String,
        initialAXTitle: String?,
        finalAXTitle: String?,
        doc: String?,
        docReadFailed: Bool,
        previousCGTitle: String?,
        previousAXTitle: String?,
        tabStripOutcome: ChromiumTabStripOutcome,
        rule6Record: inout ChromiumRule6Record?,
        sites: [String],
        now: TimeInterval
    ) -> ChromiumPageEvaluation {
        // First, check document classification
        let docClass = classifyDocument(doc: doc, readFailed: docReadFailed, sites: sites)

        // COVERED WINS:
        // A successfully read document whose host is covered is covered and starts rule 6 even if
        // titles are torn, the first title failed, the title check failed, the pass did not run,
        // or the round missed its deadline.
        if case .covered(let host) = docClass {
            rule6Record = ChromiumRule6Record(waitStart: now, host: host)
            return ChromiumPageEvaluation(verdict: .covered, cause: nil, host: host)
        }

        // If doc read failed, verdict is cantTell / unread
        if docReadFailed || doc == nil {
            if rule6Record != nil { rule6Record?.waitStart = now }
            return ChromiumPageEvaluation(verdict: .cantTell, cause: .unread, host: nil)
        }

        guard let doc = doc else {
            if rule6Record != nil { rule6Record?.waitStart = now }
            return ChromiumPageEvaluation(verdict: .cantTell, cause: .unread, host: nil)
        }

        // Extract host if document classified to one
        let docHost: String?
        switch docClass {
        case .covered(let h), .ordinaryHttp(let h):
            docHost = h
        default:
            docHost = nil
        }

        // If initial or final AX title failed to read
        guard let initialAX = initialAXTitle, let finalAX = finalAXTitle else {
            if rule6Record != nil { rule6Record?.waitStart = now }
            return ChromiumPageEvaluation(verdict: .cantTell, cause: .unread, host: docHost)
        }

        // Two AX titles that differ -> can't tell, cause unclear
        if initialAX != finalAX {
            if rule6Record != nil { rule6Record?.waitStart = now }
            return ChromiumPageEvaluation(verdict: .cantTell, cause: .unclear, host: docHost)
        }

        // Torn pair: CG title changed since previous read while AX title did not
        if let prevCG = previousCGTitle, let prevAX = previousAXTitle,
           cgTitle != prevCG, initialAX == prevAX {
            if rule6Record != nil { rule6Record?.waitStart = now }
            return ChromiumPageEvaluation(verdict: .cantTell, cause: .unclear, host: docHost)
        }

        // Empty document handling
        if doc.isEmpty {
            if cgTitle.isEmpty && initialAX.isEmpty {
                if case .counts(_, let total) = tabStripOutcome, total == 0 {
                    if let r6 = rule6Record {
                        if now - r6.waitStart < 5.0 {
                            return ChromiumPageEvaluation(verdict: .cantTell, cause: .unclear, host: nil)
                        } else {
                            rule6Record = nil
                            return ChromiumPageEvaluation(verdict: .ordinary, cause: nil, host: nil)
                        }
                    }
                    return ChromiumPageEvaluation(verdict: .ordinary, cause: nil, host: nil)
                }
            }
            if rule6Record != nil { rule6Record?.waitStart = now }
            return ChromiumPageEvaluation(verdict: .cantTell, cause: .unclear, host: nil)
        }

        // Extract tab button counts if available
        let tabCounts: (selected: Int, total: Int)?
        switch tabStripOutcome {
        case .counts(let sel, let tot): tabCounts = (sel, tot)
        default: tabCounts = nil
        }

        // Title check
        let titleCheck = checkTitles(
            cgTitle: cgTitle,
            axTitle: initialAX,
            browser: browser,
            tabButtonCount: tabCounts?.total
        )

        // Rule 4: Single pane requirement
        let singlePane: Bool
        switch titleCheck {
        case .appWindow:
            singlePane = true
        case .plain:
            if let counts = tabCounts {
                singlePane = counts.selected == 1 || counts.total == 0
            } else {
                singlePane = false
            }
        case .inserted:
            if let counts = tabCounts {
                singlePane = counts.selected == 1
            } else {
                singlePane = false
            }
        case .failed:
            singlePane = false
        }

        guard singlePane else {
            if rule6Record != nil { rule6Record?.waitStart = now }
            return ChromiumPageEvaluation(verdict: .cantTell, cause: .unclear, host: docHost)
        }

        // Check document classification for ordinary
        switch docClass {
        case .ordinaryNonHttp:
            // Check Rule 6 memory
            if let r6 = rule6Record {
                if now - r6.waitStart < 5.0 {
                    return ChromiumPageEvaluation(verdict: .cantTell, cause: .unclear, host: nil)
                } else {
                    rule6Record = nil
                    return ChromiumPageEvaluation(verdict: .ordinary, cause: nil, host: nil)
                }
            }
            return ChromiumPageEvaluation(verdict: .ordinary, cause: nil, host: nil)

        case .ordinaryHttp(let host):
            // Check Rule 6 memory
            if let r6 = rule6Record {
                if now - r6.waitStart < 5.0 {
                    return ChromiumPageEvaluation(verdict: .cantTell, cause: .unclear, host: host)
                } else {
                    rule6Record = nil
                    return ChromiumPageEvaluation(verdict: .ordinary, cause: nil, host: host)
                }
            }
            return ChromiumPageEvaluation(verdict: .ordinary, cause: nil, host: host)

        case .cantTell(let cause):
            if rule6Record != nil { rule6Record?.waitStart = now }
            return ChromiumPageEvaluation(verdict: .cantTell, cause: cause, host: docHost)

        case .covered(let host):
            rule6Record = ChromiumRule6Record(waitStart: now, host: host)
            return ChromiumPageEvaluation(verdict: .covered, cause: nil, host: host)
        }
    }

    /// Pure function evaluating one Chromium page window (value overload).
    public static func evaluatePageWindow(
        windowID: CGWindowID,
        browser: PrivateBrowser,
        cgTitle: String,
        initialAXTitle: String?,
        finalAXTitle: String?,
        doc: String?,
        docReadFailed: Bool,
        previousCGTitle: String?,
        previousAXTitle: String?,
        tabStripOutcome: ChromiumTabStripOutcome,
        rule6Record: ChromiumRule6Record?,
        sites: [String],
        now: TimeInterval
    ) -> ChromiumPageEvaluation {
        var r = rule6Record
        return evaluatePageWindow(
            windowID: windowID,
            browser: browser,
            cgTitle: cgTitle,
            initialAXTitle: initialAXTitle,
            finalAXTitle: finalAXTitle,
            doc: doc,
            docReadFailed: docReadFailed,
            previousCGTitle: previousCGTitle,
            previousAXTitle: previousAXTitle,
            tabStripOutcome: tabStripOutcome,
            rule6Record: &r,
            sites: sites,
            now: now
        )
    }

    /// Evaluates one side window (layer 3) from collected static-text values and walk outcome (with inout rule 6 record).
    public static func evaluateSideWindow(
        windowID: CGWindowID,
        staticTexts: [String],
        walkOutcome: WalkOutcome,
        rule6Record: inout ChromiumRule6Record?,
        sites: [String],
        now: TimeInterval
    ) -> ChromiumPageEvaluation {
        if walkOutcome == .failed || walkOutcome == .timedOut {
            if rule6Record != nil { rule6Record?.waitStart = now }
            return ChromiumPageEvaluation(verdict: .cantTell, cause: .unread, host: nil)
        }
        if walkOutcome == .overBudget {
            if rule6Record != nil { rule6Record?.waitStart = now }
            return ChromiumPageEvaluation(verdict: .cantTell, cause: .unclear, host: nil)
        }

        // Side-window host: no spaces; localhost or at least one dot whose last label is letters only; optional port.
        var hosts = Set<String>()
        for text in staticTexts {
            let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.contains(where: { $0.isWhitespace }) { continue }

            var hostPort = candidate
            // Strip scheme if present
            if let schemeRange = hostPort.range(of: "://") {
                hostPort = String(hostPort[schemeRange.upperBound...])
            }
            // Strip trailing path/query/fragment
            if let slashIdx = hostPort.firstIndex(of: "/") {
                hostPort = String(hostPort[..<slashIdx])
            }
            if let qIdx = hostPort.firstIndex(of: "?") {
                hostPort = String(hostPort[..<qIdx])
            }
            if let fIdx = hostPort.firstIndex(of: "#") {
                hostPort = String(hostPort[..<fIdx])
            }

            // Strip port
            var rawHost = hostPort
            if let colonIdx = hostPort.lastIndex(of: ":") {
                let portPart = hostPort[hostPort.index(after: colonIdx)...]
                if Int(portPart) != nil {
                    rawHost = String(hostPort[..<colonIdx])
                }
            }

            let lower = rawHost.lowercased()
            if lower == "localhost" {
                hosts.insert("localhost")
                continue
            }
            if lower.contains(".") {
                let parts = lower.split(separator: ".", omittingEmptySubsequences: false)
                if parts.count >= 2, let last = parts.last, !last.isEmpty,
                   last.allSatisfy({ ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") }) {
                    hosts.insert(lower)
                }
            }
        }

        // Covered if any host is covered
        for h in hosts {
            if sites.contains(where: { SiteRule.covers(siteHost: $0, host: h) }) {
                rule6Record = ChromiumRule6Record(waitStart: now, host: h)
                return ChromiumPageEvaluation(verdict: .covered, cause: nil, host: h)
            }
        }

        // Ordinary if exactly one host and it is not covered
        if hosts.count == 1, let h = hosts.first {
            if let r6 = rule6Record {
                if now - r6.waitStart < 5.0 {
                    return ChromiumPageEvaluation(verdict: .cantTell, cause: .unclear, host: h)
                } else {
                    rule6Record = nil
                    return ChromiumPageEvaluation(verdict: .ordinary, cause: nil, host: h)
                }
            }
            return ChromiumPageEvaluation(verdict: .ordinary, cause: nil, host: h)
        }

        // Otherwise can't tell
        if rule6Record != nil { rule6Record?.waitStart = now }
        return ChromiumPageEvaluation(verdict: .cantTell, cause: .unclear, host: nil)
    }

    /// Evaluates one side window (layer 3) from collected static-text values and walk outcome (value overload).
    public static func evaluateSideWindow(
        windowID: CGWindowID,
        staticTexts: [String],
        walkOutcome: WalkOutcome,
        rule6Record: ChromiumRule6Record?,
        sites: [String],
        now: TimeInterval
    ) -> ChromiumPageEvaluation {
        var r = rule6Record
        return evaluateSideWindow(
            windowID: windowID,
            staticTexts: staticTexts,
            walkOutcome: walkOutcome,
            rule6Record: &r,
            sites: sites,
            now: now
        )
    }

    public enum WalkOutcome: Sendable, Equatable {
        case complete
        case overBudget
        case timedOut
        case failed
    }

    /// Evaluates for DesktopActivity (rules 1, 2, 3, 5 for non-empty list; rules 1-3 for empty list).
    public static func evaluateActivity(
        browser: PrivateBrowser,
        cgTitle: String,
        axTitle: String,
        doc: String?,
        docReadFailed: Bool,
        previousCGTitle: String?,
        previousAXTitle: String?,
        tabStripOutcome: ChromiumTabStripOutcome,
        sites: [String]
    ) -> ChromiumPageEvaluation {
        if docReadFailed || doc == nil {
            return ChromiumPageEvaluation(verdict: .cantTell, cause: .unread, host: nil)
        }
        guard let doc = doc else {
            return ChromiumPageEvaluation(verdict: .cantTell, cause: .unread, host: nil)
        }

        // Rule 1: Empty doc
        if doc.isEmpty {
            if cgTitle.isEmpty && axTitle.isEmpty {
                if case .counts(_, let total) = tabStripOutcome, total == 0 {
                    return ChromiumPageEvaluation(verdict: .ordinary, cause: nil, host: nil)
                }
            }
            return ChromiumPageEvaluation(verdict: .cantTell, cause: .unclear, host: nil)
        }

        // Unwrap filesystem:, blob:, and view-source:
        let isWrapped = doc.hasPrefix("filesystem:") || doc.hasPrefix("blob:") || doc.hasPrefix("view-source:")
        let docHost = SiteRule.normalizeReadHost(doc)

        if isWrapped && docHost == nil {
            return ChromiumPageEvaluation(verdict: .cantTell, cause: .unclear, host: nil)
        }

        // COVERED WINS:
        if let host = docHost, !sites.isEmpty && sites.contains(where: { SiteRule.covers(siteHost: $0, host: host) }) {
            return ChromiumPageEvaluation(verdict: .covered, cause: nil, host: host)
        }

        // Torn pair check
        if let prevCG = previousCGTitle, let prevAX = previousAXTitle,
           cgTitle != prevCG, axTitle == prevAX {
            return ChromiumPageEvaluation(verdict: .cantTell, cause: .unclear, host: docHost)
        }

        // Rule 2: Title check
        let tabCounts: (selected: Int, total: Int)?
        switch tabStripOutcome {
        case .counts(let sel, let tot): tabCounts = (sel, tot)
        default: tabCounts = nil
        }
        let titleCheck = checkTitles(
            cgTitle: cgTitle,
            axTitle: axTitle,
            browser: browser,
            tabButtonCount: tabCounts?.total
        )
        if titleCheck == .failed {
            return ChromiumPageEvaluation(verdict: .cantTell, cause: .unclear, host: docHost)
        }

        // Rule 3: URL scheme classification
        if doc.hasPrefix("about:blank") || doc.hasPrefix("about:srcdoc") {
            return ChromiumPageEvaluation(verdict: .cantTell, cause: .unclear, host: nil)
        }
        let nonHttpOrdinary = ["file:", "data:", "about:", "chrome:", "edge:", "brave:", "chrome-extension:"]
        for s in nonHttpOrdinary {
            if doc.hasPrefix(s) {
                return ChromiumPageEvaluation(verdict: .ordinary, cause: nil, host: nil)
            }
        }
        let nonHttpCantTell = ["chrome-error:", "chrome-untrusted:", "ftp:"]
        for s in nonHttpCantTell {
            if doc.hasPrefix(s) {
                return ChromiumPageEvaluation(verdict: .cantTell, cause: .unclear, host: nil)
            }
        }

        guard let host = docHost else {
            return ChromiumPageEvaluation(verdict: .cantTell, cause: .unclear, host: nil)
        }

        // Rule 5: Covered check (when sites not empty)
        if !sites.isEmpty && sites.contains(where: { SiteRule.covers(siteHost: $0, host: host) }) {
            return ChromiumPageEvaluation(verdict: .covered, cause: nil, host: host)
        }

        return ChromiumPageEvaluation(verdict: .ordinary, cause: nil, host: host)
    }
}
