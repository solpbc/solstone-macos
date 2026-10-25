// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SolstoneCore

public enum ServiceMode: String, Codable, Equatable, Sendable, CaseIterable {
    case bundled
    case external

    public static let bundledServiceURL = "http://localhost:5015"
}

/// Fingerprint of an audio interface layout: stream spans and aggregate subdevices
public struct MicrophoneLayoutFingerprint: Codable, Equatable, Sendable {
    public struct StreamSpan: Codable, Equatable, Sendable {
        public let startingChannel: Int
        public let channelCount: Int

        public init(startingChannel: Int, channelCount: Int) {
            self.startingChannel = startingChannel
            self.channelCount = channelCount
        }
    }

    public struct AggregateMemberSpan: Codable, Equatable, Sendable {
        public let uid: String
        public let inputChannelCount: Int

        public init(uid: String, inputChannelCount: Int) {
            self.uid = uid
            self.inputChannelCount = inputChannelCount
        }
    }

    public let streams: [StreamSpan]
    public let aggregateMembers: [AggregateMemberSpan]?
    /// Active aggregate members in HAL order. Nil for an ordinary device and for a
    /// choice saved before active membership was part of the fingerprint.
    public let activeMembers: [AggregateMemberSpan]?

    public init(streams: [StreamSpan], aggregateMembers: [AggregateMemberSpan]? = nil,
                activeMembers: [AggregateMemberSpan]? = nil) {
        self.streams = streams
        self.aggregateMembers = aggregateMembers
        self.activeMembers = activeMembers
    }

    private enum CodingKeys: String, CodingKey {
        case streams, aggregateMembers, activeMembers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streams = try container.decode([StreamSpan].self, forKey: .streams)
        aggregateMembers = try container.decodeIfPresent([AggregateMemberSpan].self, forKey: .aggregateMembers)
        activeMembers = try container.decodeIfPresent([AggregateMemberSpan].self, forKey: .activeMembers)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(streams, forKey: .streams)
        try container.encodeIfPresent(aggregateMembers, forKey: .aggregateMembers)
        try container.encodeIfPresent(activeMembers, forKey: .activeMembers)
    }
}

/// The owner's input selection: ordinal and matching layout fingerprint
public struct MicrophoneChoice: Codable, Equatable, Sendable {
    public let ordinal: Int
    public let fingerprint: MicrophoneLayoutFingerprint

    public init(ordinal: Int, fingerprint: MicrophoneLayoutFingerprint) {
        self.ordinal = ordinal
        self.fingerprint = fingerprint
    }
}

/// Microphone entry for priority list
public struct MicrophoneEntry: Codable, Equatable, Sendable {
    /// How the owner wants a microphone taken in.
    public enum Mode: String, Sendable, CaseIterable { case always, whenInUseElsewhere, off }

    public let uid: String
    public let name: String
    public var isDisabled: Bool
    /// When off, still take the microphone in while another app has it open
    /// (the Bluetooth default: opening an idle headset input degrades its playback).
    public var followsOtherApps: Bool
    public var choice: MicrophoneChoice?

    public init(uid: String, name: String, isDisabled: Bool = false, followsOtherApps: Bool = false, choice: MicrophoneChoice? = nil) {
        self.uid = uid
        self.name = name
        self.isDisabled = isDisabled
        self.followsOtherApps = isDisabled && followsOtherApps
        self.choice = choice
    }

    public init(uid: String, name: String, mode: Mode, choice: MicrophoneChoice? = nil) {
        self.init(uid: uid, name: name, isDisabled: mode != .always, followsOtherApps: mode == .whenInUseElsewhere, choice: choice)
    }

    public var mode: Mode { !isDisabled ? .always : (followsOtherApps ? .whenInUseElsewhere : .off) }

    // Custom decoder for backward compatibility (existing configs without isDisabled)
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = try container.decode(String.self, forKey: .uid)
        name = try container.decode(String.self, forKey: .name)
        isDisabled = try container.decodeIfPresent(Bool.self, forKey: .isDisabled) ?? false
        let follows = try container.decodeIfPresent(Bool.self, forKey: .followsOtherApps) ?? false
        followsOtherApps = isDisabled && follows
        if let decodedChoice = try? container.decodeIfPresent(MicrophoneChoice.self, forKey: .choice),
           decodedChoice.ordinal >= 0 {
            choice = decodedChoice
        } else {
            choice = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uid, forKey: .uid)
        try container.encode(name, forKey: .name)
        try container.encode(isDisabled, forKey: .isDisabled)
        try container.encode(followsOtherApps, forKey: .followsOtherApps)
        if let choice {
            try container.encode(choice, forKey: .choice)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case uid, name, isDisabled, followsOtherApps, choice
    }
}

/// App entry for exclusion list
public struct AppEntry: Codable, Equatable, Sendable {
    public let bundleID: String
    public let name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// Configuration for SolstoneCapture
/// Stored in UserDefaults
public struct AppConfig: Sendable {
    // MARK: - UserDefaults Keys

    public static let knownKeys: [String] = [
        "isScreenCaptureEnabled", "isMicrophoneCaptureEnabled", "isBrowserIntakeEnabled",
        "isActivityEnabled", "activityTitlesEnabled", "activityURLsEnabled", "activityAccessibilityEnabled",
        "activityContinuesThroughPause",
        "microphonePriority", "excludedApps", "excludedTitlePatterns",
        "excludePrivateBrowsing", "excludePrivateBrowsingAccessibility", "serverURL", "serverKey",
        "syncPaused", "debugSegments",
        "preserveSyncedSegments", "microphoneGain", "silenceMusic",
        "serviceMode", "journalPath",
        "observerName", "pauseForProtectedVideo", "protectedVideoTitlePatterns",
        "pauseShortcut"
    ]

    private enum Keys {
        static let isActivityEnabled = "isActivityEnabled"
        static let activityTitlesEnabled = "activityTitlesEnabled"
        static let activityURLsEnabled = "activityURLsEnabled"
        static let activityAccessibilityEnabled = "activityAccessibilityEnabled"
        static let activityContinuesThroughPause = "activityContinuesThroughPause"
        static let isScreenCaptureEnabled = "isScreenCaptureEnabled"
        static let isMicrophoneCaptureEnabled = "isMicrophoneCaptureEnabled"
        static let isBrowserIntakeEnabled = "isBrowserIntakeEnabled"
        static let microphonePriority = "microphonePriority"
        static let excludedApps = "excludedApps"
        static let excludedTitlePatterns = "excludedTitlePatterns"
        static let excludePrivateBrowsing = "excludePrivateBrowsing"
        static let excludePrivateBrowsingAccessibility = "excludePrivateBrowsingAccessibility"
        static let serverURL = "serverURL"
        static let syncPaused = "syncPaused"
        static let debugSegments = "debugSegments"
        static let serverKey = "serverKey"
        static let preserveSyncedSegments = "preserveSyncedSegments"
        static let microphoneGain = "microphoneGain"
        static let silenceMusic = "silenceMusic"
        static let serviceMode = "serviceMode"
        static let journalPath = "journalPath"
        static let observerName = "observerName"
        static let pauseForProtectedVideo = "pauseForProtectedVideo"
        static let protectedVideoTitlePatterns = "protectedVideoTitlePatterns"
        static let pauseShortcut = "pauseShortcut"
        static let didMigrateFromJSON = "didMigrateFromJSON"
        static let didReseedOptInMicrophones = "didReseedOptInMicrophones"
        static let reseededBluetoothMicrophoneUIDs = "reseededBluetoothMicrophoneUIDs"
        static let didReseedCaptureSourcesOn = "didReseedCaptureSourcesOn"
        static let didAddPasswordManagerExclusions = "didAddPasswordManagerExclusions"
        static let didAdoptActivityFollowsScreen = "didAdoptActivityFollowsScreen"
        static let didRecordConfigPresence = "didRecordConfigPresence"
        static let didFinishOwnerScalarConversion = "didFinishOwnerScalarConversion"
    }

    // MARK: - Activity

    // Only what the owner sets is saved. nil reads as the current default, so a later default
    // change reaches everyone who hasn't chosen.
    private var activityChoice: Bool?
    private var activityTitlesChoice: Bool?
    private var activityURLsChoice: Bool?
    private var activityThroughPauseChoice: Bool?

    /// Off only when the owner turns activity off. Otherwise activity starts and pauses with screen.
    public var isActivityEnabled: Bool {
        get { activityChoice ?? true }
        set { activityChoice = newValue }
    }

    public var activityTitlesEnabled: Bool {
        get { activityTitlesChoice ?? true }
        set { activityTitlesChoice = newValue }
    }

    public var activityURLsEnabled: Bool {
        get { activityURLsChoice ?? true }
        set { activityURLsChoice = newValue }
    }

    /// The owner's choice to keep activity running through pause, with or without screen.
    public var activityContinuesThroughPause: Bool {
        get { activityThroughPauseChoice ?? false }
        set { activityThroughPauseChoice = newValue }
    }

    /// The Accessibility reader for activity is its own permission ask, off until the owner turns it on.
    private var activityAccessibilityChoice: Bool?
    public var activityAccessibilityEnabled: Bool {
        get { activityAccessibilityChoice ?? false }
        set { activityAccessibilityChoice = newValue }
    }

    /// Activity runs with screen, or on its own when the owner keeps it on through pause.
    public var isActivitySourceOn: Bool {
        isActivityEnabled && (activityContinuesThroughPause || isScreenCaptureEnabled)
    }

    /// Whether activity still goes into the journal during a pause: when the owner keeps it on
    /// through pause, or during the protected-video pause, which activity always continues through.
    func activityGoesOn(whilePausedFor reason: PermissionSourcePauseReason) -> Bool {
        (isActivityEnabled && activityContinuesThroughPause) || (reason == .protectedVideo && isActivitySourceOn)
    }

    /// The owner's pause or stop holds activity, as it holds audio, unless activity is kept on through pause.
    public func activityHeld(paused: Bool, stopped: Bool) -> Bool {
        !activityContinuesThroughPause && (paused || stopped)
    }

    // MARK: - Properties

    /// When true, screen capture is enabled by the owner
    public var isScreenCaptureEnabled: Bool

    /// When true, microphone capture is enabled by the owner
    public var isMicrophoneCaptureEnabled: Bool

    private var isBrowserIntakeChoice: Bool?
    /// When true, browser-host intake is enabled for the owner.
    public var isBrowserIntakeEnabled: Bool {
        get { isBrowserIntakeChoice ?? true }
        set { isBrowserIntakeChoice = newValue }
    }

    /// Returns the active capture sources selected by the owner
    public var selectedSources: CaptureSources {
        var sources = CaptureSources()
        if isScreenCaptureEnabled {
            sources.insert(.screen)
        }
        if isMicrophoneCaptureEnabled {
            sources.insert(.microphone)
        }
        return sources
    }

    /// Ordered list of microphones (first = highest priority)
    public var microphonePriority: [MicrophoneEntry]

    /// Apps to exclude from screen capture (windows will be masked)
    public var excludedApps: [AppEntry]

    /// Title patterns - exclude any window whose title contains these patterns
    /// Example: "reddit" will exclude any window with "reddit" in the title
    public var excludedTitlePatterns: [String]

    private var excludePrivateBrowsingChoice: Bool?
    /// Exclude private browser windows, detected by a marker in the window title.
    /// Only Firefox shows one on the Mac (measured), so owner copy names only Firefox.
    public var excludePrivateBrowsing: Bool {
        get { excludePrivateBrowsingChoice ?? true }
        set { excludePrivateBrowsingChoice = newValue }
    }

    private var excludePrivateBrowsingAccessibilityChoice: Bool?
    /// Also match Safari, Chrome, Edge and Brave private windows by their Accessibility titles.
    /// Off unless the owner turns it on in the private-window setting, the only place the
    /// Accessibility permission is ever asked for.
    public var excludePrivateBrowsingAccessibility: Bool {
        get { excludePrivateBrowsingAccessibilityChoice ?? false }
        set { excludePrivateBrowsingAccessibilityChoice = newValue }
    }

    // MARK: - Server Upload Configuration

    /// Observer server URL (e.g., "https://solstone.example.com")
    public var serverURL: String?

    /// API key for observer server authentication
    public var serverKey: String?

    private var syncPausedChoice: Bool?
    /// When true, syncing is paused (uploads skipped, but segments still recorded locally)
    public var syncPaused: Bool {
        get { syncPausedChoice ?? false }
        set { syncPausedChoice = newValue }
    }

    private var debugSegmentsChoice: Bool?
    /// When true, use 1-minute segments instead of 5-minute (for testing)
    public var debugSegments: Bool {
        get { debugSegmentsChoice ?? false }
        set { debugSegmentsChoice = newValue }
    }

    private var preserveSyncedSegmentsChoice: Bool?
    /// When true, a segment the journal confirmed is moved to the preserved-segments folder instead of being removed
    public var preserveSyncedSegments: Bool {
        get { preserveSyncedSegmentsChoice ?? false }
        set { preserveSyncedSegmentsChoice = newValue }
    }

    private var microphoneGainChoice: Float?
    /// Microphone gain multiplier (1.0 to 8.0). Default: 2.0
    public var microphoneGain: Float {
        get { microphoneGainChoice ?? 2.0 }
        set { microphoneGainChoice = newValue }
    }

    private var silenceMusicChoice: Bool?
    /// When true, silence music-only portions of system audio during remix. Default: true
    public var silenceMusic: Bool {
        get { silenceMusicChoice ?? true }
        set { silenceMusicChoice = newValue }
    }

    /// Configured service mode. Nil means no mode has been explicitly selected yet.
    public var serviceMode: ServiceMode?

    /// Local journal data directory for bundled mode.
    public var journalPath: String?

    /// Journal-assigned observer name returned during registration.
    public var observerName: String?

    private var pauseForProtectedVideoChoice: Bool?
    /// When true, pause capture while protected video is on screen. Default: true
    public var pauseForProtectedVideo: Bool {
        get { pauseForProtectedVideoChoice ?? true }
        set { pauseForProtectedVideoChoice = newValue }
    }

    /// User-defined window title patterns for protected video detection.
    public var protectedVideoTitlePatterns: [String]

    /// Global shortcut to pause/resume recording. Nil means off.
    public var pauseShortcut: PauseShortcutChord?

    /// Default exclusions written on first run
    public static let defaultExclusions: [AppEntry] = [
        AppEntry(bundleID: "com.1password.1password", name: "1Password"),
        AppEntry(bundleID: "com.agilebits.onepassword7", name: "1Password 7"),
        AppEntry(bundleID: "com.agilebits.onepassword-osx", name: "1Password (legacy)")
    ] + passwordManagerExclusions

    /// Password manager apps that joined the defaults after 1Password. A fresh install gets them
    /// with `defaultExclusions`; an install set up before gets them once, from
    /// `addPasswordManagerExclusionsIfNeeded()`. Each bundle identifier was read from the app or its
    /// App Store record, and matches even where the name is localized. A password manager used inside
    /// a browser is part of the browser and is not matched by these.
    public static let passwordManagerExclusions: [AppEntry] = [
        AppEntry(bundleID: "com.apple.Passwords", name: "Passwords"),
        AppEntry(bundleID: "com.apple.Passwords.MenuBarExtra", name: "Passwords (menu bar)"),
        AppEntry(bundleID: "com.bitwarden.desktop", name: "Bitwarden"),
        AppEntry(bundleID: "com.dashlane.dashlanephonefinal", name: "Dashlane"),
        AppEntry(bundleID: "com.lastpass.lastpassmacdesktop", name: "LastPass"),
        AppEntry(bundleID: "org.keepassxc.keepassxc", name: "KeePassXC"),
        AppEntry(bundleID: "com.keepersecurity.passwordmanager", name: "Keeper Password Manager"),
        AppEntry(bundleID: "com.callpod.keepermac.lite", name: "Keeper (App Store)"),
        AppEntry(bundleID: "me.proton.pass.electron", name: "Proton Pass")
    ]

    public init(
        isScreenCaptureEnabled: Bool = true,
        isMicrophoneCaptureEnabled: Bool = true,
        isBrowserIntakeEnabled: Bool? = nil,
        microphonePriority: [MicrophoneEntry] = [],
        excludedApps: [AppEntry] = [],
        excludedTitlePatterns: [String] = [],
        excludePrivateBrowsing: Bool? = nil,
        excludePrivateBrowsingAccessibility: Bool? = nil,
        serverURL: String? = nil,
        serverKey: String? = nil,
        syncPaused: Bool? = nil,
        debugSegments: Bool? = nil,
        preserveSyncedSegments: Bool? = nil,
        microphoneGain: Float? = nil,
        silenceMusic: Bool? = nil,
        serviceMode: ServiceMode? = nil,
        journalPath: String? = nil,
        observerName: String? = nil,
        pauseForProtectedVideo: Bool? = nil,
        protectedVideoTitlePatterns: [String] = [],
        pauseShortcut: PauseShortcutChord? = nil
    ) {
        self.isScreenCaptureEnabled = isScreenCaptureEnabled
        self.isMicrophoneCaptureEnabled = isMicrophoneCaptureEnabled
        self.isBrowserIntakeChoice = isBrowserIntakeEnabled
        self.microphonePriority = microphonePriority
        self.excludedApps = excludedApps
        self.excludedTitlePatterns = excludedTitlePatterns
        self.excludePrivateBrowsingChoice = excludePrivateBrowsing
        self.excludePrivateBrowsingAccessibilityChoice = excludePrivateBrowsingAccessibility
        self.serverURL = serverURL
        self.serverKey = serverKey
        self.syncPausedChoice = syncPaused
        self.debugSegmentsChoice = debugSegments
        self.preserveSyncedSegmentsChoice = preserveSyncedSegments
        self.microphoneGainChoice = microphoneGain
        self.silenceMusicChoice = silenceMusic
        self.serviceMode = serviceMode
        self.journalPath = journalPath
        self.observerName = observerName
        self.pauseForProtectedVideoChoice = pauseForProtectedVideo
        self.protectedVideoTitlePatterns = protectedVideoTitlePatterns
        self.pauseShortcut = pauseShortcut
    }

    // MARK: - Load/Save

    /// Loads config from UserDefaults
    public static func load() -> AppConfig {
        CFPreferencesAppSynchronize(SolstoneIdentity.bundleIdentifier as CFString)
        return load(from: .standard)
    }

    internal static func load(from defaults: UserDefaults) -> AppConfig {
        // Load microphonePriority from JSON data
        var microphonePriority: [MicrophoneEntry] = []
        if let data = defaults.data(forKey: Keys.microphonePriority) {
            microphonePriority = (try? JSONDecoder().decode([MicrophoneEntry].self, from: data)) ?? []
        }

        // Load excludedApps from JSON data
        var excludedApps: [AppEntry] = []
        if let data = defaults.data(forKey: Keys.excludedApps) {
            excludedApps = (try? JSONDecoder().decode([AppEntry].self, from: data)) ?? []
        }

        // Builds 1.4.7 to 1.4.16 saved this app's own loopback tunnel port here while paired.
        // That port changes every launch and never names a journal, and delivery has used the
        // pairing alone since, so a saved one is dropped instead of being shown as a journal.
        let savedServerURL = defaults.string(forKey: Keys.serverURL)
        let isSavedTunnelPort = LoopbackHost.isLoopbackURL(savedServerURL)
            && !BundledJournalEndpoint.isBundledServiceURL(savedServerURL)
        let serverURL = isSavedTunnelPort ? nil : savedServerURL
        let serviceMode: ServiceMode?
        if let raw = defaults.string(forKey: Keys.serviceMode), let parsed = ServiceMode(rawValue: raw) {
            serviceMode = parsed
        } else {
            serviceMode = nil
        }

        let rawProtectedPatterns = defaults.stringArray(forKey: Keys.protectedVideoTitlePatterns) ?? []
        let protectedPatterns = rawProtectedPatterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let pauseShortcut: PauseShortcutChord?
        if let raw = defaults.string(forKey: Keys.pauseShortcut) {
            pauseShortcut = PauseShortcutChord.decode(from: raw)
        } else {
            pauseShortcut = nil
        }

        let config = AppConfig(
            isScreenCaptureEnabled: defaults.object(forKey: Keys.isScreenCaptureEnabled) as? Bool ?? true,
            isMicrophoneCaptureEnabled: defaults.object(forKey: Keys.isMicrophoneCaptureEnabled) as? Bool ?? true,
            isBrowserIntakeEnabled: defaults.object(forKey: Keys.isBrowserIntakeEnabled) as? Bool,
            microphonePriority: microphonePriority,
            excludedApps: excludedApps,
            excludedTitlePatterns: defaults.stringArray(forKey: Keys.excludedTitlePatterns) ?? [],
            excludePrivateBrowsing: defaults.object(forKey: Keys.excludePrivateBrowsing) as? Bool,
            excludePrivateBrowsingAccessibility: defaults.object(forKey: Keys.excludePrivateBrowsingAccessibility) as? Bool,
            serverURL: serverURL,
            serverKey: isSavedTunnelPort ? nil : defaults.string(forKey: Keys.serverKey),
            syncPaused: defaults.object(forKey: Keys.syncPaused) as? Bool,
            debugSegments: defaults.object(forKey: Keys.debugSegments) as? Bool,
            preserveSyncedSegments: defaults.object(forKey: Keys.preserveSyncedSegments) as? Bool,
            microphoneGain: defaults.object(forKey: Keys.microphoneGain) as? Float,
            silenceMusic: defaults.object(forKey: Keys.silenceMusic) as? Bool,
            serviceMode: serviceMode,
            journalPath: defaults.string(forKey: Keys.journalPath),
            observerName: defaults.string(forKey: Keys.observerName),
            pauseForProtectedVideo: defaults.object(forKey: Keys.pauseForProtectedVideo) as? Bool,
            protectedVideoTitlePatterns: protectedPatterns,
            pauseShortcut: pauseShortcut
        )
        var activityConfig = config
        activityConfig.activityChoice = defaults.object(forKey: Keys.isActivityEnabled) as? Bool
        activityConfig.activityTitlesChoice = defaults.object(forKey: Keys.activityTitlesEnabled) as? Bool
        activityConfig.activityURLsChoice = defaults.object(forKey: Keys.activityURLsEnabled) as? Bool
        activityConfig.activityThroughPauseChoice = defaults.object(forKey: Keys.activityContinuesThroughPause) as? Bool
        activityConfig.activityAccessibilityChoice = defaults.object(forKey: Keys.activityAccessibilityEnabled) as? Bool
        return activityConfig
    }

    /// One-shot: builds before activity followed screen saved the activity switch, window titles
    /// and browser addresses as off whether or not the owner chose that, so a saved value can't be
    /// told apart from a choice. Those three are discarded once, and read as the current defaults.
    /// Adoption still leaves the Accessibility permission choice alone; an inherited stored false
    /// is a materialized default that scalar conversion removes once. An owner choice after that stays.
    internal static func adoptActivityFollowsScreenIfNeeded(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: Keys.didAdoptActivityFollowsScreen) else { return }
        for key in [Keys.isActivityEnabled, Keys.activityTitlesEnabled, Keys.activityURLsEnabled] {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: Keys.didAdoptActivityFollowsScreen)
    }

    // Frozen default values for scalar settings. A later change to getter defaults
    // must NOT edit these constants; they represent the defaults at the time of scalar conversion.
    private static let frozenBrowserIntakeDefault: Bool = true
    private static let frozenExcludePrivateBrowsingDefault: Bool = true
    private static let frozenExcludePrivateBrowsingAccessibilityDefault: Bool = false
    private static let frozenActivityAccessibilityDefault: Bool = false
    private static let frozenSyncPausedDefault: Bool = false
    private static let frozenDebugSegmentsDefault: Bool = false
    private static let frozenPreserveSyncedSegmentsDefault: Bool = false
    private static let frozenMicrophoneGainDefault: Float = 2.0
    private static let frozenSilenceMusicDefault: Bool = true
    private static let frozenPauseForProtectedVideoDefault: Bool = true

    internal static func convertMaterializedScalarDefaultsIfNeeded(
        _ defaults: UserDefaults,
        preserving: Set<String> = []
    ) {
        guard !defaults.bool(forKey: Keys.didFinishOwnerScalarConversion) else { return }

        if defaults.object(forKey: Keys.didRecordConfigPresence) == nil {
            defaults.set(true, forKey: Keys.didRecordConfigPresence)
        }

        let boolConversions: [(String, Bool)] = [
            (Keys.isBrowserIntakeEnabled, frozenBrowserIntakeDefault),
            (Keys.excludePrivateBrowsing, frozenExcludePrivateBrowsingDefault),
            (Keys.excludePrivateBrowsingAccessibility, frozenExcludePrivateBrowsingAccessibilityDefault),
            (Keys.activityAccessibilityEnabled, frozenActivityAccessibilityDefault),
            (Keys.syncPaused, frozenSyncPausedDefault),
            (Keys.debugSegments, frozenDebugSegmentsDefault),
            (Keys.preserveSyncedSegments, frozenPreserveSyncedSegmentsDefault),
            (Keys.silenceMusic, frozenSilenceMusicDefault),
            (Keys.pauseForProtectedVideo, frozenPauseForProtectedVideoDefault)
        ]

        for (key, frozenDefault) in boolConversions where !preserving.contains(key) {
            guard let object = defaults.object(forKey: key) else { continue }
            if let value = object as? Bool {
                if value == frozenDefault {
                    defaults.removeObject(forKey: key)
                }
            } else {
                Logger.general.warning("Stored setting \(key, privacy: .public) does not cast to Bool, leaving untouched")
            }
        }

        if !preserving.contains(Keys.microphoneGain) {
            if let object = defaults.object(forKey: Keys.microphoneGain) {
                if let value = object as? Float {
                    if value == frozenMicrophoneGainDefault {
                        defaults.removeObject(forKey: Keys.microphoneGain)
                    }
                } else {
                    Logger.general.warning("Stored setting \(Keys.microphoneGain, privacy: .public) does not cast to Float, leaving untouched")
                }
            }
        }

        defaults.set(true, forKey: Keys.didFinishOwnerScalarConversion)
    }

    /// Loads config or creates with defaults if missing
    /// Also migrates from config.json if present
    public static func loadOrCreateDefault(
        legacyConfigPaths: [URL]? = nil,
        log: any ClassifiedLogSinking = LoggerClassifiedLogSink.general,
        continuationDirectory: URL? = nil,
        nativeSetupEnabled: Bool = false,
        continuationStore: SetupContinuationStore? = nil,
        defaults: UserDefaults = .standard
    ) throws -> AppConfig {
        let legacyConfigPaths = legacyConfigPaths ?? productionLegacyConfigPaths

        // Before anything below can save, so no old activity value is carried forward.
        adoptActivityFollowsScreenIfNeeded(defaults)

        let isExistingDomain = defaults.object(forKey: Keys.didRecordConfigPresence) != nil ||
            (defaults.object(forKey: Keys.didFinishOwnerScalarConversion) == nil && defaults.object(forKey: Keys.excludePrivateBrowsing) != nil)

        var migratedConfig: AppConfig?
        var jsonPreserving: Set<String> = []

        // Check for migration from JSON config
        if !defaults.bool(forKey: Keys.didMigrateFromJSON) {
            if let (migrated, preserving) = migrateFromJSON(
                legacyConfigPaths: legacyConfigPaths,
                log: log,
                defaults: defaults,
                isExistingDomain: isExistingDomain
            ) {
                migratedConfig = migrated
                jsonPreserving = preserving
            } else {
                // Mark migration as complete even if no file existed
                defaults.set(true, forKey: Keys.didMigrateFromJSON)
            }
        }

        // Recognize an existing install: presence marker, or legacy sentinel until conversion finishes.
        if migratedConfig != nil || isExistingDomain {
            convertMaterializedScalarDefaultsIfNeeded(defaults, preserving: jsonPreserving)
            if let migratedConfig {
                return migratedConfig
            }
            return load(from: defaults)
        }

        if nativeSetupEnabled {
            let store = continuationStore ?? SetupContinuationStore(
                directory: continuationDirectory ?? SetupContinuationStore.defaultDirectory
            )
            if try store.loadChecked() == nil {
                try store.save(SetupContinuation(phase: .journal))
            }
        }

        // Create default config only after native setup can resume.
        var defaultConfig = AppConfig(
            isScreenCaptureEnabled: !nativeSetupEnabled,
            isMicrophoneCaptureEnabled: !nativeSetupEnabled
        )
        defaultConfig.excludedApps = defaultExclusions
        try defaultConfig.save(to: defaults)
        defaults.set(true, forKey: Keys.didRecordConfigPresence)
        defaults.set(true, forKey: Keys.didReseedCaptureSourcesOn)
        defaults.set(true, forKey: Keys.didAddPasswordManagerExclusions)
        defaults.set(true, forKey: Keys.didFinishOwnerScalarConversion)
        Logger.general.info("Created default config in UserDefaults")
        return defaultConfig
    }

    /// Saves config to UserDefaults
    public func save(to defaults: UserDefaults = .standard) throws {
        for (choice, key) in [
            (activityChoice, Keys.isActivityEnabled),
            (activityTitlesChoice, Keys.activityTitlesEnabled),
            (activityURLsChoice, Keys.activityURLsEnabled),
            (activityThroughPauseChoice, Keys.activityContinuesThroughPause)
        ] {
            if let choice { defaults.set(choice, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        saveScalarChoice(activityAccessibilityChoice, forKey: Keys.activityAccessibilityEnabled, in: defaults)
        defaults.set(isScreenCaptureEnabled, forKey: Keys.isScreenCaptureEnabled)
        defaults.set(isMicrophoneCaptureEnabled, forKey: Keys.isMicrophoneCaptureEnabled)
        saveScalarChoice(isBrowserIntakeChoice, forKey: Keys.isBrowserIntakeEnabled, in: defaults)

        // Save complex types as JSON data
        if let data = try? JSONEncoder().encode(microphonePriority) {
            defaults.set(data, forKey: Keys.microphonePriority)
        }
        if let data = try? JSONEncoder().encode(excludedApps) {
            defaults.set(data, forKey: Keys.excludedApps)
        }

        defaults.set(excludedTitlePatterns, forKey: Keys.excludedTitlePatterns)
        saveScalarChoice(excludePrivateBrowsingChoice, forKey: Keys.excludePrivateBrowsing, in: defaults)
        saveScalarChoice(excludePrivateBrowsingAccessibilityChoice, forKey: Keys.excludePrivateBrowsingAccessibility, in: defaults)
        defaults.set(serverURL, forKey: Keys.serverURL)
        defaults.set(serverKey, forKey: Keys.serverKey)
        if let serviceMode {
            defaults.set(serviceMode.rawValue, forKey: Keys.serviceMode)
        } else {
            defaults.removeObject(forKey: Keys.serviceMode)
        }
        if let journalPath {
            defaults.set(journalPath, forKey: Keys.journalPath)
        } else {
            defaults.removeObject(forKey: Keys.journalPath)
        }
        if let observerName {
            defaults.set(observerName, forKey: Keys.observerName)
        } else {
            defaults.removeObject(forKey: Keys.observerName)
        }
        saveScalarChoice(syncPausedChoice, forKey: Keys.syncPaused, in: defaults)
        saveScalarChoice(debugSegmentsChoice, forKey: Keys.debugSegments, in: defaults)
        saveScalarChoice(preserveSyncedSegmentsChoice, forKey: Keys.preserveSyncedSegments, in: defaults)
        saveScalarChoice(microphoneGainChoice, forKey: Keys.microphoneGain, in: defaults)
        saveScalarChoice(silenceMusicChoice, forKey: Keys.silenceMusic, in: defaults)
        saveScalarChoice(pauseForProtectedVideoChoice, forKey: Keys.pauseForProtectedVideo, in: defaults)
        defaults.set(protectedVideoTitlePatterns, forKey: Keys.protectedVideoTitlePatterns)
        if let pauseShortcut {
            defaults.set(pauseShortcut.encodedString, forKey: Keys.pauseShortcut)
        } else {
            defaults.removeObject(forKey: Keys.pauseShortcut)
        }
    }

    private func saveScalarChoice(_ choice: Bool?, forKey key: String, in defaults: UserDefaults) {
        if let choice {
            defaults.set(choice, forKey: key)
        } else if let existing = defaults.object(forKey: key) {
            if existing as? Bool != nil {
                defaults.removeObject(forKey: key)
            }
        }
    }

    private func saveScalarChoice(_ choice: Float?, forKey key: String, in defaults: UserDefaults) {
        if let choice {
            defaults.set(choice, forKey: key)
        } else if let existing = defaults.object(forKey: key) {
            if existing as? Float != nil {
                defaults.removeObject(forKey: key)
            }
        }
    }

    // MARK: - Migration from JSON

    /// Legacy JSON config path
    private static var legacyConfigPath: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Solstone/config.json")
    }

    /// Legacy sck-cli config path
    private static var legacySckCliPath: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sck-cli.json")
    }

    private static var productionLegacyConfigPaths: [URL] {
        [legacyConfigPath, legacySckCliPath]
    }

    /// Migrates from legacy JSON config if present
    private static func migrateFromJSON(
        legacyConfigPaths pathsToTry: [URL],
        log: any ClassifiedLogSinking,
        defaults: UserDefaults,
        isExistingDomain: Bool
    ) -> (AppConfig, Set<String>)? {
        for path in pathsToTry {
            guard FileManager.default.fileExists(atPath: path.path) else {
                continue
            }

            do {
                let data = try Data(contentsOf: path)
                let legacyConfig = try JSONDecoder().decode(LegacyJSONConfig.self, from: data)

                let legacyProtectedPatterns = (legacyConfig.protectedVideoTitlePatterns ?? [])
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                let config = AppConfig(
                    microphonePriority: legacyConfig.microphonePriority ?? [],
                    excludedApps: legacyConfig.excludedApps ?? [],
                    excludedTitlePatterns: legacyConfig.excludedTitlePatterns ?? [],
                    excludePrivateBrowsing: legacyConfig.excludePrivateBrowsing,
                    serverURL: legacyConfig.serverURL,
                    serverKey: legacyConfig.serverKey,
                    syncPaused: legacyConfig.syncPaused,
                    debugSegments: legacyConfig.debugSegments,
                    microphoneGain: legacyConfig.microphoneGain,
                    silenceMusic: legacyConfig.silenceMusic,
                    pauseForProtectedVideo: legacyConfig.pauseForProtectedVideo,
                    protectedVideoTitlePatterns: legacyProtectedPatterns
                )

                if isExistingDomain {
                    defaults.set(true, forKey: Keys.didRecordConfigPresence)
                }

                try config.save(to: defaults)
                defaults.set(true, forKey: Keys.didMigrateFromJSON)

                var preserving: Set<String> = []
                if legacyConfig.excludePrivateBrowsing != nil { preserving.insert(Keys.excludePrivateBrowsing) }
                if legacyConfig.syncPaused != nil { preserving.insert(Keys.syncPaused) }
                if legacyConfig.debugSegments != nil { preserving.insert(Keys.debugSegments) }
                if legacyConfig.microphoneGain != nil { preserving.insert(Keys.microphoneGain) }
                if legacyConfig.silenceMusic != nil { preserving.insert(Keys.silenceMusic) }
                if legacyConfig.pauseForProtectedVideo != nil { preserving.insert(Keys.pauseForProtectedVideo) }

                log.emit(
                    ClassifiedLogEmission(
                        level: .info,
                        classification: "config-migrated",
                        publicFields: legacyMigrationFields(for: path)
                    )
                )

                // Optionally rename old file to indicate migration
                let backupPath = path.appendingPathExtension("migrated")
                try? FileManager.default.moveItem(at: path, to: backupPath)

                return (config, preserving)
            } catch {
                log.emit(
                    ClassifiedLogEmission(
                        level: .warning,
                        classification: "config-migrate-failed",
                        publicFields: legacyMigrationFields(for: path)
                    )
                )
            }
        }

        return nil
    }

    private static func legacyMigrationFields(for path: URL) -> [String: String] {
        let filename = path.lastPathComponent
        let source: String
        switch filename {
        case ".sck-cli.json":
            source = "legacy-sck-cli"
        default:
            source = "legacy-config"
        }
        return ["source": source, "filename": filename]
    }

    // MARK: - Microphone Methods

    /// Returns UIDs of disabled microphones
    public var disabledMicrophoneUIDs: Set<String> {
        Set(microphonePriority.filter { $0.mode == .off }.map { $0.uid })
    }

    /// Returns UIDs of enabled microphones
    public var enabledMicrophoneUIDs: Set<String> {
        Set(microphonePriority.filter { !$0.isDisabled }.map { $0.uid })
    }

    /// One-shot repair for installs that persisted both capture sources as off.
    ///
    /// 2.0.6 shipped `isScreenCaptureEnabled` / `isMicrophoneCaptureEnabled` defaulting to
    /// `false`, and any config save on that build wrote those `false` values into UserDefaults.
    /// Reading an absent key as `true` (see `load()`) rescues an install that never saved, but
    /// not one that did — so those machines need their sources turned back on exactly once.
    ///
    /// Every FRESH 2.0.6 install saved: `loadOrCreateDefault()` persists the default config
    /// unconditionally when no config exists. An upgraded install saved as soon as anything
    /// called `updateConfig` — a settings change, journal pairing, observer-name registration —
    /// or when `syncMicrophonePriorityList()` met a microphone UID it had not seen before.
    /// So this is not a belt-and-braces migration; without it a large share of 2.0.6 machines
    /// stay silently off forever.
    ///
    /// A choice the owner makes after this runs is never touched again.
    public mutating func reseedCaptureSourcesOnIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Keys.didReseedCaptureSourcesOn) else {
            return
        }

        guard !isScreenCaptureEnabled, !isMicrophoneCaptureEnabled else {
            // Nothing to repair: at least one source is already on, which is either the
            // healthy default or a choice the owner made. Close the one-shot either way.
            defaults.set(true, forKey: Keys.didReseedCaptureSourcesOn)
            return
        }

        var reseeded = self
        reseeded.isScreenCaptureEnabled = true
        reseeded.isMicrophoneCaptureEnabled = true

        do {
            try reseeded.save()
            self = reseeded
            // Only close the one-shot once the repair is actually persisted — a failed save
            // must leave the install eligible for the repair on its next launch.
            defaults.set(true, forKey: Keys.didReseedCaptureSourcesOn)
            Logger.general.info("Re-seeded both capture sources on after the 2.0.6 default-off regression")
        } catch {
            Logger.general.warning("Failed to re-seed capture sources on: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One-shot: an install set up before the password manager apps joined the defaults gets them
    /// once. Only `passwordManagerExclusions` missing from the list are added, so an app the owner
    /// took out before (the 1Password entries were defaults from the start) stays out, and one the
    /// owner takes out after this runs is never added back.
    public mutating func addPasswordManagerExclusionsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Keys.didAddPasswordManagerExclusions) else {
            return
        }

        var updated = self
        for entry in Self.passwordManagerExclusions where !updated.excludedApps.contains(where: {
            $0.bundleID == entry.bundleID || $0.name.lowercased() == entry.name.lowercased()
        }) {
            updated.excludedApps.append(entry)
        }

        do {
            try updated.save()
            self = updated
            // Closed only once saved, so a failed save tries again on the next launch.
            defaults.set(true, forKey: Keys.didAddPasswordManagerExclusions)
        } catch {
            Logger.general.warning("Failed to add the password manager exclusions: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One-shot migration that disables connected opt-in-only microphones previously saved as enabled.
    public mutating func reseedOptInOnlyMicrophonesIfNeeded(connectedOptInOnlyUIDs: Set<String>) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Keys.didReseedOptInMicrophones) else {
            return
        }

        var reseeded = self
        reseeded.microphonePriority = reseeded.microphonePriority.map { entry in
            guard connectedOptInOnlyUIDs.contains(entry.uid), !entry.isDisabled else {
                return entry
            }
            return MicrophoneEntry(uid: entry.uid, name: entry.name, isDisabled: true, followsOtherApps: entry.followsOtherApps, choice: entry.choice)
        }

        do {
            try reseeded.save()
            self = reseeded
            defaults.set(true, forKey: Keys.didReseedOptInMicrophones)
        } catch {
            Logger.general.warning("Failed to re-seed opt-in microphone defaults: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Toggles the disabled state of a microphone
    public mutating func toggleMicrophoneDisabled(uid: String) {
        guard let index = microphonePriority.firstIndex(where: { $0.uid == uid }) else { return }
        let entry = microphonePriority[index]
        microphonePriority[index] = MicrophoneEntry(uid: entry.uid, name: entry.name, isDisabled: !entry.isDisabled, followsOtherApps: entry.followsOtherApps, choice: entry.choice)
    }

    public mutating func setMicrophoneMode(uid: String, mode: MicrophoneEntry.Mode) {
        guard let index = microphonePriority.firstIndex(where: { $0.uid == uid }) else { return }
        let entry = microphonePriority[index]
        microphonePriority[index] = MicrophoneEntry(uid: entry.uid, name: entry.name, mode: mode, choice: entry.choice)
    }

    @discardableResult
    public mutating func setMicrophoneChoice(uid: String, choice: MicrophoneChoice?) -> Bool {
        guard let index = microphonePriority.firstIndex(where: { $0.uid == uid }) else { return false }
        let entry = microphonePriority[index]
        microphonePriority[index] = MicrophoneEntry(uid: entry.uid, name: entry.name, isDisabled: entry.isDisabled, followsOtherApps: entry.followsOtherApps, choice: choice)
        return true
    }

    /// Once per headset, the first time it is seen connected: a Bluetooth microphone
    /// still on the old automatic "always" now follows other apps instead, so an idle
    /// headset keeps its playback quality. A choice made after that is never revisited.
    @discardableResult
    public mutating func reseedBluetoothMicrophones(connectedBluetoothUIDs: Set<String>) -> Bool {
        let defaults = UserDefaults.standard
        var seen = Set(defaults.stringArray(forKey: Keys.reseededBluetoothMicrophoneUIDs) ?? [])
        let fresh = connectedBluetoothUIDs.subtracting(seen)
        guard !fresh.isEmpty else { return false }
        var reseeded = self, changed = false
        reseeded.microphonePriority = reseeded.microphonePriority.map { entry in
            guard fresh.contains(entry.uid), entry.mode == .always else { return entry }
            changed = true
            return MicrophoneEntry(uid: entry.uid, name: entry.name, mode: .whenInUseElsewhere, choice: entry.choice)
        }
        do {
            if changed { try reseeded.save() }
            self = reseeded
            seen.formUnion(fresh)
            defaults.set(seen.sorted(), forKey: Keys.reseededBluetoothMicrophoneUIDs)
        } catch {
            Logger.general.warning("Failed to re-seed Bluetooth microphone defaults: \(error.localizedDescription, privacy: .public)")
        }
        return changed
    }

    /// The Bluetooth devices seen by the existing per-headset default migration.
    /// Their transport remains known even while they are disconnected or off.
    static var knownBluetoothMicrophoneUIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Keys.reseededBluetoothMicrophoneUIDs) ?? [])
    }

    /// Reorders microphones in the priority list
    public mutating func reorderMicrophones(fromOffsets: IndexSet, toOffset: Int) {
        let movingEntries = fromOffsets.map { microphonePriority[$0] }
        let adjustedDestination = toOffset - fromOffsets.filter { $0 < toOffset }.count

        for index in fromOffsets.sorted(by: >) {
            microphonePriority.remove(at: index)
        }

        microphonePriority.insert(contentsOf: movingEntries, at: adjustedDestination)
    }

    /// Removes a microphone from the priority list
    public mutating func removeMicrophone(uid: String) -> Bool {
        let countBefore = microphonePriority.count
        microphonePriority.removeAll(where: { $0.uid == uid })
        return microphonePriority.count < countBefore
    }

    // MARK: - App Exclusion Methods

    /// The keys an excluded app is matched by: its name and its bundle identifier. The identifier
    /// still matches when the name is localized or changes. An app added by name has a made-up
    /// `user.excluded.` identifier, which matches nothing.
    public var excludedAppNames: [String] {
        excludedApps.flatMap { [$0.name, $0.bundleID] }
    }

    /// Checks if an app is excluded
    public func isAppExcluded(bundleID: String) -> Bool {
        excludedApps.contains(where: { $0.bundleID == bundleID })
    }

    /// Adds an app to the exclusion list
    public mutating func excludeApp(bundleID: String, name: String) -> Bool {
        guard !excludedApps.contains(where: { $0.bundleID == bundleID }) else {
            return false
        }
        excludedApps.append(AppEntry(bundleID: bundleID, name: name))
        return true
    }

    /// Removes an app from the exclusion list
    public mutating func includeApp(bundleID: String) -> Bool {
        let countBefore = excludedApps.count
        excludedApps.removeAll(where: { $0.bundleID == bundleID })
        return excludedApps.count < countBefore
    }

    // MARK: - Server Upload Methods

    /// Check if server upload is configured
    public var isUploadConfigured: Bool {
        guard let url = serverURL, !url.isEmpty,
              let key = serverKey, !key.isEmpty else {
            return false
        }
        return true
    }

    // MARK: - Protected Video Methods

    @discardableResult
    public mutating func addProtectedVideoTitlePattern(_ pattern: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if !protectedVideoTitlePatterns.contains(where: { $0.lowercased() == trimmed.lowercased() }) {
            protectedVideoTitlePatterns.append(trimmed)
            return true
        }
        return false
    }

    @discardableResult
    public mutating func removeProtectedVideoTitlePattern(_ pattern: String) -> Bool {
        let countBefore = protectedVideoTitlePatterns.count
        protectedVideoTitlePatterns.removeAll { $0.lowercased() == pattern.lowercased() }
        return protectedVideoTitlePatterns.count < countBefore
    }
}

// MARK: - Legacy JSON Config for Migration

private struct LegacyJSONConfig: Codable {
    var microphonePriority: [MicrophoneEntry]?
    var excludedApps: [AppEntry]?
    var excludedTitlePatterns: [String]?
    var excludePrivateBrowsing: Bool?
    var serverURL: String?
    var serverKey: String?
    var syncPaused: Bool?
    var debugSegments: Bool?
    var microphoneGain: Float?
    var silenceMusic: Bool?
    var pauseForProtectedVideo: Bool?
    var protectedVideoTitlePatterns: [String]?
}
