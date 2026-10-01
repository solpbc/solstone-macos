// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Foundation
import SolstoneCore

extension BrowserBrand {
    public var displayName: String {
        switch self {
        case .chrome: return "Chrome"
        case .edge: return "Edge"
        case .firefox: return "Firefox"
        }
    }
}

public enum BrowserOwnerStatusLead: Equatable, Sendable {
    case mediaUnchanged
    case draining
    case ready
    case waiting
    case paused
    case intakeOff
    case notPaired
    case unavailable
    case shutdown
    case custodyFull
    case hold(String)
    case sessionClosed
    case unknown
}

public struct BrowserOwnerVerdict: Equatable, Sendable {
    public var lead: BrowserOwnerStatusLead
    public var fullSecondary: Bool
    public var stale: Bool
    public var showsDeliveryLine: Bool

    public init(lead: BrowserOwnerStatusLead, fullSecondary: Bool, stale: Bool, showsDeliveryLine: Bool) {
        self.lead = lead
        self.fullSecondary = fullSecondary
        self.stale = stale
        self.showsDeliveryLine = showsDeliveryLine
    }
}

public enum BrowserRelativeTimeBucket: Equatable, Sendable {
    case justNow
    case minutes(Int)
    case hours(Int)
    case yesterday
    case date(Date)
}

public enum SourcesToggle: Equatable, Sendable {
    case microphone(Bool)
    case screen(Bool)
    case browserPages(Bool)
}

public enum BrowserStoreLaunch: Equatable, Sendable {
    case disabled
    case opened
    case failed
}

public struct BrowserStoreCatalog: Equatable, Sendable {
    public var urls: [BrowserBrand: URL]

    public static let preview = BrowserStoreCatalog(urls: [:])

    public init(urls: [BrowserBrand: URL] = [:]) {
        self.urls = urls
    }

    public func url(for brand: BrowserBrand) -> URL? { urls[brand] }
}

public struct BrowserRepairToken: Equatable, Sendable {
    public var attempt: Int
    public var destinationGeneration: Int
    public var lifecycleGeneration: Int
    public var viewGeneration: Int

    public init(attempt: Int, destinationGeneration: Int, lifecycleGeneration: Int, viewGeneration: Int) {
        self.attempt = attempt
        self.destinationGeneration = destinationGeneration
        self.lifecycleGeneration = lifecycleGeneration
        self.viewGeneration = viewGeneration
    }
}

final class BrowserRepairValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0
    var value: UInt64 { lock.withLock { revision } }
    func invalidate() { lock.withLock { revision &+= 1 } }
    func matches(_ captured: UInt64) -> Bool { lock.withLock { revision == captured } }
}

public struct BrowserRepairController: Equatable, Sendable {
    public var destinationGeneration = 0
    public var lifecycleGeneration = 0
    public var viewGeneration = 0
    public var inFlight = false
    public var attempt = 0
    public var results: [BrowserBrand: BrowserHostRegistrationSummary] = [:]
    public var repaired = false
    public var lastFailureReason: String?

    public init() {}

    public mutating func click() -> BrowserRepairToken? {
        guard !inFlight else { return nil }
        inFlight = true
        repaired = false
        lastFailureReason = nil
        attempt += 1
        return BrowserRepairToken(
            attempt: attempt,
            destinationGeneration: destinationGeneration,
            lifecycleGeneration: lifecycleGeneration,
            viewGeneration: viewGeneration
        )
    }

    public mutating func complete(
        token: BrowserRepairToken,
        report: BrowserHostRegistrationReport,
        devReport: BrowserHostRegistrationReport? = nil,
        listenerHoldsFence: Bool,
        endpoint: BrowserHostEndpointDisposition?
    ) {
        guard inFlight, token.attempt == attempt else { return }
        inFlight = false
        guard token.destinationGeneration == destinationGeneration,
              token.lifecycleGeneration == lifecycleGeneration,
              token.viewGeneration == viewGeneration else { return }
        results = Dictionary(uniqueKeysWithValues: report.outcomes.map { brand, outcome in
            (brand, BrowserHostRegistrationSummary(state: outcome.state, reasonCode: outcome.reasonCode))
        })
        let dev = devReport ?? report
        let allVerified = BrowserBrand.allCases.allSatisfy { brand in
            let prodState = report.outcomes[brand]?.state
            let devState = dev.outcomes[brand]?.state
            let prodOk = prodState == .ready || prodState == .changed
            let devOk = devState == .ready || devState == .changed
            return prodOk && devOk
        }
        repaired = report.isComplete && dev.isComplete && allVerified && listenerHoldsFence
        if !repaired {
            if let firstRefused = report.outcomes.values.first(where: { $0.state == .refused }) ?? dev.outcomes.values.first(where: { $0.state == .refused }),
               let reason = firstRefused.reasonCode {
                lastFailureReason = reason
            } else if !listenerHoldsFence {
                lastFailureReason = "listener_down"
            } else {
                lastFailureReason = "registration_incomplete"
            }
        }
    }
}

public struct BrowserBrandRow: Equatable, Sendable {
    public var brand: BrowserBrand
    public var connectedCount: Int
    public var lastSeen: BrowserRelativeTimeBucket?
    public var registration: BrowserHostRegistrationState
    public var needsAppUpdate = false
    public var needsExtensionUpdate = false

    public var state: BrowserProfileAXState {
        if needsAppUpdate { return .needsAppUpdate }
        if needsExtensionUpdate { return .needsExtensionUpdate }
        if connectedCount > 0 { return .connected }
        if lastSeen != nil { return .lastSeen }
        return .none
    }

    public init(brand: BrowserBrand, connectedCount: Int, lastSeen: BrowserRelativeTimeBucket?, registration: BrowserHostRegistrationState) {
        self.brand = brand
        self.connectedCount = connectedCount
        self.lastSeen = lastSeen
        self.registration = registration
    }
}

public struct BrowserDiagnosticRow: Equatable, Sendable {
    public let label: String
    public let humanValue: String
    public let machineValue: String

    public init(label: String, humanValue: String, machineValue: String) {
        self.label = label
        self.humanValue = humanValue
        self.machineValue = machineValue
    }
}

public func sourcesToggleRestartsMedia(_ toggle: SourcesToggle) -> Bool {
    switch toggle {
    case .microphone, .screen: return true
    case .browserPages: return false
    }
}

public func menuPauseControls(
    mediaRecording: Bool,
    mediaPaused: Bool,
    mediaUserPaused: Bool,
    pauseManagerPaused: Bool,
    browserCapturePermitted: Bool
) -> (pause: Bool, resume: Bool) {
    let resume = mediaUserPaused || (!mediaRecording && pauseManagerPaused && browserCapturePermitted)
    let pause = !resume && (
        (mediaRecording && !mediaPaused) ||
        (!mediaRecording && !mediaPaused && browserCapturePermitted && !pauseManagerPaused)
    )
    return (pause, resume)
}

public func browserPresentsLocalReceiptAsDelivered(_ delivery: String) -> Bool {
    delivery == "delivered"
}

public func browserShowsDeliveryLine(_ delivery: String) -> Bool {
    delivery == "failed"
}

public func statusPrimaryDelivery<Outcome: Equatable>(media: Outcome, browserDelivery: String) -> Outcome {
    _ = browserDelivery
    return media
}

public func browserSetupGroupIsVisible(screenGranted: Bool, microphoneGranted: Bool) -> Bool {
    _ = (screenGranted, microphoneGranted)
    return true
}

public func browserRelativeTimeBucket(lastSeen: Date, now: Date, calendar: Calendar = .current) -> BrowserRelativeTimeBucket {
    let dayDelta = calendar.dateComponents(
        [.day],
        from: calendar.startOfDay(for: lastSeen),
        to: calendar.startOfDay(for: now)
    ).day ?? 0
    if dayDelta < 0 { return .justNow }
    if dayDelta == 0 {
        let interval = now.timeIntervalSince(lastSeen)
        if interval < 60 { return .justNow }
        if interval < 3_600 { return .minutes(Int(interval / 60)) }
        return .hours(max(1, Int(interval / 3_600)))
    }
    if dayDelta == 1 { return .yesterday }
    return .date(calendar.startOfDay(for: lastSeen))
}

public func browserOwnerVerdict(
    mediaSourcesEmpty: Bool,
    mediaRecording: Bool,
    mediaPaused: Bool,
    snapshot: BrowserHostSnapshotValue,
    now: Date
) -> BrowserOwnerVerdict {
    let queued = snapshot.delivery == "kept_locally" || snapshot.delivery == "failed"
    if mediaSourcesEmpty, !mediaRecording, !mediaPaused, !snapshot.intakeEnabled, queued {
        return BrowserOwnerVerdict(
            lead: .draining,
            fullSecondary: snapshot.custodyPresent && snapshot.custodyFull,
            stale: snapshot.custodyStale,
            showsDeliveryLine: browserShowsDeliveryLine(snapshot.delivery)
        )
    }

    let full = inferredFull(snapshot)
    let blockingHold = ownerHold(snapshot)
    let fullPrimary = snapshot.intakeEnabled && full && blockingHold == nil && (
        snapshot.capture == "permitted" || snapshot.capture == "intake_off"
    )
    let fullSecondary = full && !fullPrimary
    let deliveryLine = browserShowsDeliveryLine(snapshot.delivery)

    if snapshot.shutdown || snapshot.quiescence {
        return BrowserOwnerVerdict(lead: .shutdown, fullSecondary: fullSecondary, stale: snapshot.custodyStale, showsDeliveryLine: deliveryLine)
    }
    switch snapshot.capture {
    case "paused":
        return BrowserOwnerVerdict(lead: .paused, fullSecondary: fullSecondary, stale: snapshot.custodyStale, showsDeliveryLine: deliveryLine)
    case "not_paired":
        return BrowserOwnerVerdict(lead: .notPaired, fullSecondary: fullSecondary, stale: snapshot.custodyStale, showsDeliveryLine: deliveryLine)
    case "unavailable":
        return BrowserOwnerVerdict(lead: .unavailable, fullSecondary: fullSecondary, stale: snapshot.custodyStale, showsDeliveryLine: deliveryLine)
    case "intake_off":
        if !snapshot.intakeEnabled {
            return BrowserOwnerVerdict(lead: .intakeOff, fullSecondary: full, stale: snapshot.custodyStale, showsDeliveryLine: deliveryLine)
        }
        if let blockingHold {
            return BrowserOwnerVerdict(lead: .hold(blockingHold), fullSecondary: fullSecondary, stale: snapshot.custodyStale, showsDeliveryLine: deliveryLine)
        }
        if fullPrimary {
            return BrowserOwnerVerdict(lead: .custodyFull, fullSecondary: false, stale: snapshot.custodyStale, showsDeliveryLine: deliveryLine)
        }
        return BrowserOwnerVerdict(lead: .intakeOff, fullSecondary: fullSecondary, stale: snapshot.custodyStale, showsDeliveryLine: deliveryLine)
    case "permitted":
        if snapshot.listener != .available {
            return BrowserOwnerVerdict(lead: .unavailable, fullSecondary: fullSecondary, stale: snapshot.custodyStale, showsDeliveryLine: deliveryLine)
        }
        if let blockingHold {
            return BrowserOwnerVerdict(lead: .hold(blockingHold), fullSecondary: fullSecondary, stale: snapshot.custodyStale, showsDeliveryLine: deliveryLine)
        }
        if fullPrimary {
            return BrowserOwnerVerdict(lead: .custodyFull, fullSecondary: false, stale: snapshot.custodyStale, showsDeliveryLine: deliveryLine)
        }
        let allProfiles = snapshot.profiles.chrome + snapshot.profiles.edge + snapshot.profiles.firefox
        let liveProfiles = allProfiles.filter { sessionAuthorizes($0, now: now) }
        if liveProfiles.isEmpty {
            return BrowserOwnerVerdict(lead: .waiting, fullSecondary: fullSecondary, stale: snapshot.custodyStale, showsDeliveryLine: deliveryLine)
        }
        return BrowserOwnerVerdict(lead: .ready, fullSecondary: false, stale: snapshot.custodyStale, showsDeliveryLine: deliveryLine)
    default:
        return BrowserOwnerVerdict(lead: mediaSourcesEmpty && snapshot.intakeEnabled ? .unknown : .mediaUnchanged,
                                  fullSecondary: fullSecondary, stale: snapshot.custodyStale, showsDeliveryLine: deliveryLine)
    }
}

public func browserOwnerStatusLead(
    mediaSourcesEmpty: Bool,
    mediaRecording: Bool,
    mediaPaused: Bool,
    snapshot: BrowserHostSnapshotValue,
    now: Date
) -> BrowserOwnerStatusLead {
    browserOwnerVerdict(
        mediaSourcesEmpty: mediaSourcesEmpty,
        mediaRecording: mediaRecording,
        mediaPaused: mediaPaused,
        snapshot: snapshot,
        now: now
    ).lead
}

public func sourcesFooter(media: String, lead: BrowserOwnerStatusLead) -> String {
    switch lead {
    case .draining:
        return UICopy.SOURCES_BROWSER_DRAINING
    case .mediaUnchanged:
        return media
    case .notPaired, .unavailable:
        return UICopy.SOURCES_BROWSER_CANNOT_START
    case .unknown:
        return UICopy.SOURCES_BROWSER_UNKNOWN
    case .intakeOff:
        return UICopy.SOURCES_BROWSER_INTAKE_OFF
    case .paused:
        return UICopy.SOURCES_BROWSER_PAUSED
    case .shutdown, .sessionClosed:
        return UICopy.SOURCES_BROWSER_INTAKE_OFF
    case .ready:
        return UICopy.SOURCES_BROWSER_HEADLINE_READY
    case .waiting:
        return UICopy.SOURCES_BROWSER_HEADLINE_WAITING
    case .custodyFull:
        return UICopy.SOURCES_BROWSER_FULL
    case .hold(let reason):
        return reason == "unaccepted_lost" ? UICopy.SOURCES_BROWSER_LOST_AND_HELD : UICopy.SOURCES_BROWSER_HELD
    }
}

public func browserBrandRows(_ snapshot: BrowserHostSnapshotValue, now: Date, calendar: Calendar = .current) -> [BrowserBrandRow] {
    BrowserBrand.allCases.map { brand in
        let profiles = profiles(snapshot, brand)
        let authorizing = profiles.filter { sessionAuthorizes($0, now: now) }
        let last = profiles.compactMap(\.lastSeen).max()
        var row = BrowserBrandRow(
            brand: brand,
            connectedCount: authorizing.count,
            lastSeen: last.map { browserRelativeTimeBucket(lastSeen: $0, now: now, calendar: calendar) },
            registration: snapshot.registration[brand]?.state ?? .unknown
        )
        row.needsAppUpdate = profiles.contains { $0.handshake == .unsupportedApp }
        row.needsExtensionUpdate = profiles.contains { $0.handshake == .unsupportedExtension }
        return row
    }
}

public func formatRelativeBucket(_ bucket: BrowserRelativeTimeBucket) -> String {
    switch bucket {
    case .justNow:
        return "just now"
    case .minutes(let m):
        return "\(m) min ago"
    case .hours(let h):
        return h == 1 ? "1 hour ago" : "\(h) hours ago"
    case .yesterday:
        return "yesterday"
    case .date(let d):
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: d)
    }
}

public func buildBrowserDiagnosticRows(
    snapshot: BrowserHostSnapshotValue,
    repair: BrowserRepairController,
    now: Date,
    calendar: Calendar = .current
) -> [BrowserDiagnosticRow] {
    let pagesHuman: String
    let pagesMachine: String
    if !snapshot.intakeEnabled {
        pagesHuman = "off"
        pagesMachine = "off"
    } else if snapshot.capture == "paused" {
        pagesHuman = "paused"
        pagesMachine = "paused"
    } else if let hold = ownerHold(snapshot) {
        pagesHuman = "held"
        pagesMachine = hold
    } else if browserIntakeIsReady(snapshot, now: now) {
        pagesHuman = "on"
        pagesMachine = "on"
    } else {
        pagesHuman = "held"
        pagesMachine = snapshot.listener != .available ? "listener_down" : "intake_unavailable"
    }

    let rows = browserBrandRows(snapshot, now: now, calendar: calendar)
    let seenParts = rows.compactMap { row -> String? in
        guard let bucket = row.lastSeen else { return nil }
        return "\(row.brand.displayName) (\(formatRelativeBucket(bucket)))"
    }
    let browsersSeen = seenParts.isEmpty ? "none yet" : seenParts.joined(separator: ", ")

    let allReady = BrowserBrand.allCases.allSatisfy {
        snapshot.registration[$0]?.state == .ready || snapshot.registration[$0]?.state == .changed
    }
    let setupValue: String
    if allReady && snapshot.listener == .available {
        let brandNames = BrowserBrand.allCases.map(\.displayName).joined(separator: ", ")
        setupValue = "\(brandNames) ready"
    } else {
        let brandParts = BrowserBrand.allCases.map { brand -> String in
            let reg = snapshot.registration[brand]
            if snapshot.listener == .available, reg?.state == .changed {
                return "\(brand.displayName): repaired at launch"
            }
            if snapshot.listener == .available, reg?.state == .ready {
                return "\(brand.displayName): ready"
            }
            let reason = UICopy.browserSetupReason(snapshot.listener == .available ? reg?.reasonCode : "listener_down")
            return "\(brand.displayName): couldn't set up (\(reason))"
        }
        setupValue = brandParts.joined(separator: ", ")
    }

    return [
        BrowserDiagnosticRow(
            label: UICopy.DIAGNOSTICS_BROWSER_PAGES_LABEL,
            humanValue: pagesHuman,
            machineValue: pagesMachine
        ),
        BrowserDiagnosticRow(
            label: UICopy.DIAGNOSTICS_BROWSERS_SEEN_LABEL,
            humanValue: browsersSeen,
            machineValue: browsersSeen
        ),
        BrowserDiagnosticRow(
            label: UICopy.DIAGNOSTICS_BROWSER_SETUP_LABEL,
            humanValue: setupValue,
            machineValue: setupValue
        )
    ]
}

public func menubarBrowserRowTitle(snapshot: BrowserHostSnapshotValue, now: Date) -> String {
    guard snapshot.intakeEnabled else {
        return UICopy.MENUBAR_BROWSERS_OFF
    }
    if snapshot.capture == "paused" {
        return UICopy.MENUBAR_BROWSERS_PAUSED
    }
    let allProfiles = [
        (BrowserBrand.chrome, snapshot.profiles.chrome),
        (BrowserBrand.edge, snapshot.profiles.edge),
        (BrowserBrand.firefox, snapshot.profiles.firefox)
    ]
    let liveBrands = allProfiles.compactMap { (brand, profiles) -> String? in
        let live = profiles.filter { sessionAuthorizes($0, now: now) }
        return live.isEmpty ? nil : brand.displayName
    }
    if !liveBrands.isEmpty {
        return UICopy.menubarBrowsersLive(liveBrands.joined(separator: ", "))
    }
    let hasHistory = allProfiles.contains { _, profiles in !profiles.isEmpty }
    if hasHistory {
        return UICopy.MENUBAR_BROWSERS_NONE_CONNECTED
    }
    return UICopy.MENUBAR_BROWSERS_NONE_YET
}

public func performBrowserStoreOpen(
    brand: BrowserBrand,
    catalog: BrowserStoreCatalog,
    open: (URL, BrowserBrand) -> Bool
) -> BrowserStoreLaunch {
    guard let url = catalog.url(for: brand) else { return .disabled }
    return open(url, brand) ? .opened : .failed
}

public func browserCapturePermitsPause(_ snapshot: BrowserHostSnapshotValue, now: Date) -> Bool {
    guard snapshot.intakeEnabled, !snapshot.shutdown, !snapshot.quiescence else { return false }
    return true
}

public func browserIntakeIsReady(_ snapshot: BrowserHostSnapshotValue, now: Date) -> Bool {
    guard snapshot.intakeEnabled else { return false }
    let verdict = browserOwnerVerdict(
        mediaSourcesEmpty: true, mediaRecording: false, mediaPaused: false,
        snapshot: snapshot, now: now
    )
    return verdict.lead == .ready || verdict.lead == .waiting
}

extension StatusHealthSummary {
    public static func makeIncludingBrowser(
        serviceMode: ServiceMode?,
        isRecording: Bool,
        isPaused: Bool,
        held: Bool,
        uploadStatus: UploadCoordinator.Status,
        pendingCount: Int,
        lastDeliveryOutcome: LastJournalDeliveryOutcome,
        serverURL: String?,
        pairedJournalAddress: String? = nil,
        now: Date,
        selectedSources: CaptureSources = .all,
        permittedSources: CaptureSources = .all,
        errorMessage: String? = nil,
        setupVerdict: SetupGroupVerdict? = nil,
        lastHealthReason: ObserverHealthFailureReason? = nil,
        snapshot: BrowserHostSnapshotValue
    ) -> StatusHealthSummary {
        let media = StatusHealthSummary.make(
            serviceMode: serviceMode,
            isRecording: isRecording,
            isPaused: isPaused,
            held: held,
            uploadStatus: uploadStatus,
            pendingCount: pendingCount,
            lastDeliveryOutcome: lastDeliveryOutcome,
            serverURL: serverURL,
            pairedJournalAddress: pairedJournalAddress,
            now: now,
            selectedSources: selectedSources,
            permittedSources: permittedSources,
            errorMessage: errorMessage,
            setupVerdict: setupVerdict,
            lastHealthReason: lastHealthReason
        )
        if isRecording || isPaused { return media }
        let verdict = browserOwnerVerdict(
            mediaSourcesEmpty: selectedSources.isEmpty,
            mediaRecording: isRecording,
            mediaPaused: isPaused,
            snapshot: snapshot,
            now: now
        )
        let details = [
            verdict.fullSecondary ? UICopy.SOURCES_BROWSER_FULL : nil,
            verdict.stale ? UICopy.SOURCES_BROWSER_STALE : nil,
            verdict.showsDeliveryLine ? UICopy.SOURCES_BROWSER_DELIVERY_FAILED : nil
        ].compactMap { $0 }
        let deliverySubtitle = details.isEmpty ? nil : details.joined(separator: "\n")
        switch verdict.lead {
        case .draining:
            return StatusHealthSummary(
                severity: .calm,
                title: UICopy.SOURCES_BROWSER_DRAINING,
                subtitle: deliverySubtitle,
                axValue: "browser_draining",
                action: StatusHealthAction(label: UICopy.SOURCES_OPEN_ACTION, settingsTab: "sources", reasksJournalMark: false)
            )
        case .ready:
            return StatusHealthSummary(
                severity: .good,
                title: UICopy.SOURCES_BROWSER_HEADLINE_READY,
                subtitle: deliverySubtitle,
                axValue: "browser_ready"
            )
        case .waiting:
            return StatusHealthSummary(
                severity: .calm,
                title: UICopy.SOURCES_BROWSER_HEADLINE_WAITING,
                subtitle: deliverySubtitle,
                axValue: "browser_waiting"
            )
        case .custodyFull:
            return StatusHealthSummary(
                severity: .warn,
                title: UICopy.SOURCES_BROWSER_FULL,
                subtitle: deliverySubtitle,
                axValue: "custody_full",
                action: StatusHealthAction(label: UICopy.SOURCES_OPEN_ACTION, settingsTab: "sources", reasksJournalMark: false)
            )
        case .paused:
            return StatusHealthSummary(
                severity: .calm,
                title: UICopy.SOURCES_BROWSER_PAUSED,
                subtitle: deliverySubtitle,
                axValue: "browser_paused"
            )
        case .hold(let reason):
            let title = reason == "unaccepted_lost" ? UICopy.SOURCES_BROWSER_LOST_AND_HELD : UICopy.SOURCES_BROWSER_HELD
            return StatusHealthSummary(
                severity: .attention,
                title: title,
                subtitle: deliverySubtitle,
                axValue: "browser_hold"
            )
        case .shutdown:
            return StatusHealthSummary(
                severity: .calm,
                title: UICopy.SOURCES_BROWSER_INTAKE_OFF,
                subtitle: deliverySubtitle,
                axValue: "browser_shutdown"
            )
        case .sessionClosed:
            return StatusHealthSummary(
                severity: .calm,
                title: UICopy.SOURCES_BROWSER_INTAKE_OFF,
                subtitle: deliverySubtitle,
                axValue: "browser_closed"
            )
        case .intakeOff:
            return StatusHealthSummary(
                severity: .calm,
                title: UICopy.SOURCES_BROWSER_INTAKE_OFF,
                subtitle: deliverySubtitle,
                axValue: "browser_off"
            )
        case .notPaired, .unavailable:
            return StatusHealthSummary(severity: .attention, title: UICopy.SOURCES_BROWSER_CANNOT_START,
                subtitle: deliverySubtitle, axValue: "browser_unavailable",
                action: StatusHealthAction(label: UICopy.SOURCES_OPEN_ACTION, settingsTab: "sources", reasksJournalMark: false))
        case .unknown:
            return StatusHealthSummary(severity: .calm, title: UICopy.SOURCES_BROWSER_UNKNOWN,
                subtitle: deliverySubtitle, axValue: "browser_unknown")
        case .mediaUnchanged:
            return media
        }
    }
}

private func inferredFull(_ snapshot: BrowserHostSnapshotValue) -> Bool {
    snapshot.custodyPresent && snapshot.custodyFull
}

private func ownerHold(_ snapshot: BrowserHostSnapshotValue) -> String? {
    switch snapshot.failureCode {
    case "unaccepted_lost", "local_io", "age_policy":
        return snapshot.failureCode
    case "resource_exhausted", "queue_full":
        return inferredFull(snapshot) ? nil : snapshot.failureCode
    case "relay_unavailable", "journal_rejected":
        return snapshot.capture == "intake_off" ? snapshot.failureCode : nil
    default:
        return nil
    }
}

private func sessionAuthorizes(_ snapshot: BrowserHostSnapshotValue, now: Date) -> Bool {
    let profiles = snapshot.profiles.chrome + snapshot.profiles.edge + snapshot.profiles.firefox
    if profiles.isEmpty { return false }
    return profiles.contains { sessionAuthorizes($0, now: now) }
}

private func sessionAuthorizes(_ profile: BrowserHostProfile, now: Date) -> Bool {
    guard profile.handshake == .compatible,
          profile.byeReason == nil,
          let expiry = profile.leaseExpiry,
          let seen = profile.lastSeen else { return false }
    return expiry.timeIntervalSince(seen) > 0 && expiry > now
}

private func profiles(_ snapshot: BrowserHostSnapshotValue, _ brand: BrowserBrand) -> [BrowserHostProfile] {
    switch brand {
    case .chrome: return snapshot.profiles.chrome
    case .edge: return snapshot.profiles.edge
    case .firefox: return snapshot.profiles.firefox
    }
}

private func listenerToken(_ state: BrowserHostListenerState) -> String {
    switch state {
    case .available: return "available"
    case .unavailable: return "unavailable"
    case .collision: return "collision"
    case .pathTooLong: return "path_too_long"
    }
}

#endif
