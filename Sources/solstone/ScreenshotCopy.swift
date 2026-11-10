// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Owner strings for the screenshots source, each keyed to its id.
/// The words are the locked copy. Do not retype them here.
enum ScreenshotCopy {
    static let label = "screenshots" // S1
    static let fromBeforeToday = "from before today" // S7
    static let last30Days = "the last 30 days" // S8
    static let last6Months = "the last 6 months"
    static let lastYear = "the last year"
    static let allOfIt = "all of it"
    static let nothingFromBeforeToday = "nothing from before today"
    static let seeTheCount = "you'll see how many screenshots there are before any come in." // S9
    static let chooseHowFar = "choose how far back to start, then bring them in." // S11
    static let couldntCount = "couldn't count your screenshots." // S12
    static let tryAgain = "try again"
    static let checking = "checking…"
    static let staysIfDeleted = "a screenshot already in your journal stays there if you delete it from the folder." // S14
    static let staysWhenPaused = "what's already in your journal stays when you pause or turn this off." // S15
    static let pausedSkips = "screenshots you take while it's paused don't come in." // S16, second sentence
    static let notBroughtAgain = "screenshots already in your journal aren't brought in again." // S17
    static let lastChecked = "last checked" // S18
    static let waitingLabel = "waiting to go to your journal" // S19
    static let waitingForJournal = "waiting for a journal update. your screenshots wait on this mac." // S21
    static let folderLabel = "folder" // S22
    static let onlyWhatWeCanTell = "only what the solstone app can tell is a screenshot comes in." // S23
    static let takesIn = "while this is on, the solstone app takes in the screenshots you take on this mac, and your journal keeps each one at the minute you took it." // D1
    static let allow = "allow" // D4
    static let openSystemSettings = "open system settings" // D5
    static let clipboard = "a screenshot copied to the clipboard isn't saved, so it doesn't come in." // D7
    static let chooseFolder = "choose a folder…" // D8's button, also the mac page control
    static let moreAboutThis = "more about this" // D15
    static let soFar = "so far"
    static let lastTakenIn = "last taken in"
    static let resume = "resume"

    static func fromFolder(_ line: String) -> String { "from \(line)" } // S4

    static func tileProgress(done: Int, total: Int) -> String {
        "\(done) of \(total) in your journal" // S5
    }

    static func pageProgress(done: Int, total: Int) -> String {
        "\(done) of \(total) screenshots in your journal" // S6
    }

    static func confirmTitle(spanFromToday: Bool, count: Int) -> String {
        if spanFromToday || count == 0 { return "start from today" } // S10
        if count == 1 { return "bring in 1 screenshot" }
        return "bring in \(count) screenshots"
    }

    static func total(_ count: Int) -> String {
        count == 1 ? "1 screenshot" : "\(grouped(count)) screenshots" // S20
    }

    static func needsFolder(_ name: String) -> String {
        "screenshots on this mac save to your \(name). the solstone app needs access to that folder." // D4
    }

    static func accessOff(_ name: String) -> String {
        "access to your \(name) folder is off for the solstone app." // D5
    }

    static func locationMoved(_ name: String) -> String {
        "screenshots now save to \(name). the solstone app needs access to that folder." // D6
    }

    static func desktopStays(_ name: String) -> String {
        "other files on your \(name) stay where they are." // D2
    }

    static func folderStays(_ name: String) -> String {
        "other files in \(name) stay where they are." // D3
    }

    static func refusedLine(_ count: Int) -> String? {
        if count <= 0 { return nil } // D12
        if count == 1 { return "1 screenshot can't come in, so it stays in the folder." }
        return "\(count) screenshots can't come in, so they stay in the folder."
    }

    static func unreadableLine(_ count: Int) -> String? {
        if count <= 0 { return nil } // D13
        if count == 1 { return "couldn't read 1 screenshot." }
        return "couldn't read \(count) screenshots."
    }

    private static func grouped(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: count)) ?? String(count)
    }
}
