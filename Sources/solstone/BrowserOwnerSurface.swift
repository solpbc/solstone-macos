// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Foundation
import SolstoneCore

/// Section 5 owner sentences were not in this repo. Nil hides the line instead of inventing one.
enum BrowserOwnerCopy {
    static let intakeToggleLabel: String? = nil
    static let helpLegendFootnote: String? = nil
    static let drainingReason: String? = nil
    static let storeActionLabel: String? = nil
}

enum BrowserOwnerStatusLead: Equatable {
    case mediaUnchanged
    case draining
    case ready
    case paused
    case intakeOff
    case notPaired
    case unavailable
    case shutdown
    case custodyFull
    case hold(String)
    case sessionClosed
}

struct BrowserOwnerVerdict: Equatable {
    var lead: BrowserOwnerStatusLead
    var fullSecondary: Bool
    var stale: Bool
    var showsDeliveryLine: Bool
}

enum BrowserRelativeTimeBucket: Equatable {
    case justNow
    case minutes(Int)
    case hours(Int)
    case yesterday
    case date(Date)
}

enum SourcesToggle: Equatable {
    case microphone(Bool)
    case screen(Bool)
    case browserPages(Bool)
}

enum BrowserStoreLaunch: Equatable {
    case disabled
    case opened
    case failed
}

struct BrowserStoreCatalog: Equatable {
    var urls: [BrowserBrand: URL]

    static let preview = BrowserStoreCatalog(urls: [:])

    func url(for brand: BrowserBrand) -> URL? { urls[brand] }
}

struct BrowserRepairToken: Equatable {
    var attempt: Int
    var destinationGeneration: Int
    var lifecycleGeneration: Int
    var viewGeneration: Int
}

struct BrowserRepairController: Equatable {
    var destinationGeneration = 0
    var lifecycleGeneration = 0
    var viewGeneration = 0
    var inFlight = false
    var attempt = 0
    var results: [BrowserBrand: BrowserHostRegistrationSummary] = [:]
    var repaired = false

    mutating func click() -> BrowserRepairToken? {
        guard !inFlight else { return nil }
        inFlight = true
        repaired = false
        attempt += 1
        return BrowserRepairToken(
            attempt: attempt,
            destinationGeneration: destinationGeneration,
            lifecycleGeneration: lifecycleGeneration,
            viewGeneration: viewGeneration
        )
    }

    mutating func complete(
        token: BrowserRepairToken,
        report: BrowserHostRegistrationReport,
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
        let endpointOK = listenerHoldsFence || endpoint == .absent || endpoint == .removed
        repaired = report.isComplete && endpointOK
    }
}

struct BrowserBrandRow: Equatable {
    var brand: BrowserBrand
    var connectedCount: Int
    var lastSeen: BrowserRelativeTimeBucket?
    var registration: BrowserHostRegistrationState
}

struct BrowserOwnerDiagnosticLine: Equatable {
    var key: String
    var value: String
}

func sourcesToggleRestartsMedia(_ toggle: SourcesToggle) -> Bool {
    switch toggle {
    case .microphone, .screen: return true
    case .browserPages: return false
    }
}

func menuPauseControls(
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

func browserPresentsLocalReceiptAsDelivered(_ delivery: String) -> Bool {
    delivery == "delivered"
}

func browserShowsDeliveryLine(_ delivery: String) -> Bool {
    switch delivery {
    case "delivered", "kept_locally", "idle":
        return false
    default:
        return true
    }
}

func statusPrimaryDelivery<Outcome: Equatable>(media: Outcome, browserDelivery: String) -> Outcome {
    _ = browserDelivery
    return media
}

func browserSetupGroupIsVisible(screenGranted: Bool, microphoneGranted: Bool) -> Bool {
    _ = (screenGranted, microphoneGranted)
    return true
}

func browserRelativeTimeBucket(lastSeen: Date, now: Date, calendar: Calendar = .current) -> BrowserRelativeTimeBucket {
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

func browserOwnerVerdict(
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
            showsDeliveryLine: false
        )
    }

    let full = inferredFull(snapshot)
    let blockingHold = ownerHold(snapshot)
    let fullPrimary = full && blockingHold == nil && (
        snapshot.capture == "permitted" || snapshot.capture == "intake_off" || snapshot.failureCode == "queue_full"
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
        if let blockingHold {
            return BrowserOwnerVerdict(lead: .hold(blockingHold), fullSecondary: fullSecondary, stale: snapshot.custodyStale, showsDeliveryLine: deliveryLine)
        }
        if fullPrimary {
            return BrowserOwnerVerdict(lead: .custodyFull, fullSecondary: false, stale: snapshot.custodyStale, showsDeliveryLine: deliveryLine)
        }
        return BrowserOwnerVerdict(lead: .intakeOff, fullSecondary: fullSecondary, stale: snapshot.custodyStale, showsDeliveryLine: deliveryLine)
    case "permitted":
        if let blockingHold {
            return BrowserOwnerVerdict(lead: .hold(blockingHold), fullSecondary: fullSecondary, stale: snapshot.custodyStale, showsDeliveryLine: deliveryLine)
        }
        if fullPrimary {
            return BrowserOwnerVerdict(lead: .custodyFull, fullSecondary: false, stale: snapshot.custodyStale, showsDeliveryLine: deliveryLine)
        }
        if !sessionAuthorizes(snapshot, now: now) {
            return BrowserOwnerVerdict(lead: .sessionClosed, fullSecondary: fullSecondary, stale: snapshot.custodyStale, showsDeliveryLine: deliveryLine)
        }
        return BrowserOwnerVerdict(lead: .ready, fullSecondary: false, stale: snapshot.custodyStale, showsDeliveryLine: deliveryLine)
    default:
        return BrowserOwnerVerdict(lead: .mediaUnchanged, fullSecondary: fullSecondary, stale: snapshot.custodyStale, showsDeliveryLine: deliveryLine)
    }
}

func browserOwnerStatusLead(
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

func sourcesFooter(media: String, lead: BrowserOwnerStatusLead) -> String {
    switch lead {
    case .draining, .mediaUnchanged, .intakeOff, .notPaired, .unavailable:
        return media
    case .paused:
        return "paused"
    case .shutdown, .sessionClosed:
        return UICopy.SOURCES_OFF
    case .ready, .custodyFull, .hold:
        return "on"
    }
}

func browserBrandRows(_ snapshot: BrowserHostSnapshotValue, now: Date, calendar: Calendar = .current) -> [BrowserBrandRow] {
    BrowserBrand.allCases.map { brand in
        let profiles = profiles(snapshot, brand)
        let authorizing = profiles.filter { sessionAuthorizes($0, now: now) }
        let last = profiles.compactMap(\.lastSeen).max()
        return BrowserBrandRow(
            brand: brand,
            connectedCount: authorizing.count,
            lastSeen: last.map { browserRelativeTimeBucket(lastSeen: $0, now: now, calendar: calendar) },
            registration: snapshot.registration[brand]?.state ?? .unknown
        )
    }
}

func browserOwnerDiagnosticLines(_ snapshot: BrowserHostSnapshotValue, now: Date, calendar: Calendar = .current) -> [BrowserOwnerDiagnosticLine] {
    var lines = [
        BrowserOwnerDiagnosticLine(key: "intake", value: snapshot.intakeEnabled ? "on" : "off"),
        BrowserOwnerDiagnosticLine(key: "capture", value: snapshot.capture),
        BrowserOwnerDiagnosticLine(key: "listener", value: listenerToken(snapshot.listener)),
        BrowserOwnerDiagnosticLine(key: "custody_full", value: snapshot.custodyPresent ? (snapshot.custodyFull ? "full" : "not_full") : "unknown"),
        BrowserOwnerDiagnosticLine(key: "custody_stale", value: snapshot.custodyPresent ? (snapshot.custodyStale ? "stale" : "not_stale") : "unknown"),
    ]
    if browserShowsDeliveryLine(snapshot.delivery) {
        lines.append(BrowserOwnerDiagnosticLine(key: "delivery", value: snapshot.delivery == "unknown" ? "unknown" : snapshot.delivery))
    }
    for row in browserBrandRows(snapshot, now: now, calendar: calendar) {
        lines.append(BrowserOwnerDiagnosticLine(key: row.brand.rawValue, value: "\(row.registration.rawValue) \(row.connectedCount)"))
    }
    return lines
}

func performBrowserStoreOpen(
    brand: BrowserBrand,
    catalog: BrowserStoreCatalog,
    open: (URL, BrowserBrand) -> Bool
) -> BrowserStoreLaunch {
    guard let url = catalog.url(for: brand) else { return .disabled }
    return open(url, brand) ? .opened : .failed
}

func browserCapturePermitsPause(_ snapshot: BrowserHostSnapshotValue, now: Date) -> Bool {
    guard snapshot.intakeEnabled, snapshot.capture == "permitted", !snapshot.shutdown, !snapshot.quiescence else { return false }
    return sessionAuthorizes(snapshot, now: now) && !inferredFull(snapshot)
}

extension StatusHealthSummary {
    static func makeIncludingBrowser(
        serviceMode: ServiceMode?,
        isRecording: Bool,
        isPaused: Bool,
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
        switch verdict.lead {
        case .draining:
            return StatusHealthSummary(
                severity: .calm,
                title: UICopy.SOURCES_NONE,
                subtitle: BrowserOwnerCopy.drainingReason,
                axValue: "browser_draining",
                action: StatusHealthAction(label: UICopy.SOURCES_OPEN_ACTION, settingsTab: "sources")
            )
        case .ready:
            return StatusHealthSummary(severity: .good, title: "on", subtitle: nil, axValue: "browser_ready")
        case .custodyFull:
            return StatusHealthSummary(
                severity: .warn,
                title: "on",
                subtitle: nil,
                axValue: "custody_full",
                action: StatusHealthAction(label: UICopy.SOURCES_OPEN_ACTION, settingsTab: "sources")
            )
        case .paused:
            return StatusHealthSummary(severity: .calm, title: "paused", subtitle: nil, axValue: "browser_paused")
        case .hold:
            return StatusHealthSummary(severity: .attention, title: "on", subtitle: nil, axValue: "browser_hold")
        case .shutdown:
            return StatusHealthSummary(severity: .calm, title: "on", subtitle: nil, axValue: "browser_shutdown")
        case .sessionClosed:
            return StatusHealthSummary(severity: .calm, title: UICopy.SOURCES_OFF, subtitle: nil, axValue: "browser_closed")
        case .mediaUnchanged, .intakeOff, .notPaired, .unavailable:
            return media
        }
    }
}

private func inferredFull(_ snapshot: BrowserHostSnapshotValue) -> Bool {
    if snapshot.custodyPresent {
        if snapshot.failureCode == "queue_full", !snapshot.custodyFull { return false }
        if snapshot.failureCode == "resource_exhausted", !snapshot.custodyFull { return false }
        return snapshot.custodyFull
    }
    return snapshot.failureCode == "queue_full"
}

private func ownerHold(_ snapshot: BrowserHostSnapshotValue) -> String? {
    switch snapshot.failureCode {
    case "unaccepted_lost", "relay_unavailable", "journal_rejected", "local_io", "age_policy", "resource_exhausted":
        return snapshot.failureCode
    default:
        return nil
    }
}

private func sessionAuthorizes(_ snapshot: BrowserHostSnapshotValue, now: Date) -> Bool {
    let profiles = snapshot.profiles.chrome + snapshot.profiles.edge + snapshot.profiles.firefox
    if profiles.isEmpty { return true }
    return profiles.contains { sessionAuthorizes($0, now: now) }
}

private func sessionAuthorizes(_ profile: BrowserHostProfile, now: Date) -> Bool {
    guard profile.byeReason == nil, let expiry = profile.leaseExpiry, let seen = profile.lastSeen else { return false }
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
