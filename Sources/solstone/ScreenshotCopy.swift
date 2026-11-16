// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Owner strings for the screenshots source, each keyed to its id.
/// The words are the locked copy. Do not retype them here.
enum ScreenshotCopy {
    static let label = MacStrings.macos_screenshot_screenshots2() // S1
    static let fromBeforeToday = MacStrings.macos_screenshot_frombeforetoday() // S7
    static let last30Days = MacStrings.macos_screenshot_thelast30days() // S8
    static let last6Months = MacStrings.macos_screenshot_thelast6months()
    static let lastYear = MacStrings.macos_screenshot_thelastyear()
    static let allOfIt = MacStrings.macos_screenshot_allofit()
    static let nothingFromBeforeToday = MacStrings.macos_screenshot_nothingfrombeforetoday()
    static let seeTheCount = MacStrings.macos_screenshot_youllseehow() // S9
    static let chooseHowFar = MacStrings.macos_screenshot_choosehowfarback() // S11
    static let couldntCount = MacStrings.macos_screenshot_couldntcountyour() // S12
    static let tryAgain = MacStrings.macos_desktop_shared_copy_tryagain()
    static let checking = MacStrings.macos_screenshot_checking()
    static let staysIfDeleted = MacStrings.macos_screenshot_ascreenshotalreadyin() // S14
    static let staysWhenPaused = MacStrings.macos_screenshot_whatsalreadyin() // S15
    static let pausedSkips = MacStrings.macos_screenshot_screenshotsyoutakewhile() // S16, second sentence
    static let notBroughtAgain = MacStrings.macos_screenshot_screenshotsalreadyinyour() // S17
    static let lastChecked = MacStrings.macos_screenshot_lastchecked() // S18
    static let waitingLabel = MacStrings.macos_screenshot_waitingtogoto() // S19
    static let waitingForJournal = MacStrings.macos_screenshot_waitingforajournal() // S21
    static let folderLabel = MacStrings.macos_screenshot_folder() // S22
    static let onlyWhatWeCanTell = MacStrings.macos_screenshot_onlywhatthesolstone() // S23
    static let takesIn = MacStrings.macos_screenshot_whilethisison() // D1
    static let allow = MacStrings.macos_screenshot_allow() // D4
    static let openSystemSettings = MacStrings.macos_screenshot_opensystemsettings() // D5
    static let clipboard = MacStrings.macos_screenshot_ascreenshotcopiedto() // D7
    static let chooseFolder = MacStrings.macos_screenshot_chooseafolder() // D8's button, also the mac page control
    static let moreAboutThis = MacStrings.macos_screenshot_moreaboutthis() // D15
    static let soFar = MacStrings.macos_desktopsource_sofar()
    static let lastTakenIn = MacStrings.macos_desktopsource_lasttakenin()
    static let resume = MacStrings.macos_desktop_shared_setup_wizardpausefailure2()

    static func fromFolder(_ line: String) -> String { MacStrings.macos_screenshot_from("\(line)") } // S4

    static func tileProgress(done: Int, total: Int) -> String {
        MacStrings.macos_screenshot_ofinyourjournal("\(done)", MacStrings.number(total)) // S5
    }

    static func pageProgress(done: Int, total: Int) -> String {
        MacStrings.macos_screenshot_ofscreenshotsinyour("\(done)", MacStrings.number(total)) // S6
    }

    static func confirmTitle(spanFromToday: Bool, count: Int) -> String {
        if spanFromToday || count == 0 { return MacStrings.macos_screenshot_startfromtoday() } // S10
        return MacStrings.macos_screenshots_bringin(count)
    }

    static func total(_ count: Int) -> String {
        MacStrings.macos_screenshotcopy_screenshots_plural(count, "\(grouped(count))") // S20
    }

    static func needsFolder(_ name: String) -> String {
        MacStrings.macos_screenshot_screenshotsonthismac("\(name)") // D4
    }

    static func accessOff(_ name: String) -> String {
        MacStrings.macos_screenshot_accesstoyourfolder("\(name)") // D5
    }

    static func locationMoved(_ name: String) -> String {
        MacStrings.macos_screenshot_screenshotsnowsaveto("\(name)") // D6
    }

    static func desktopStays(_ name: String) -> String {
        MacStrings.macos_screenshot_otherfilesonyour("\(name)") // D2
    }

    static func folderStays(_ name: String) -> String {
        MacStrings.macos_screenshot_otherfilesinstay("\(name)") // D3
    }

    static func refusedLine(_ count: Int) -> String? {
        if count <= 0 { return nil } // D12
        return MacStrings.macos_screenshots_cannotbring(count)
    }

    static func unreadableLine(_ count: Int) -> String? {
        if count <= 0 { return nil } // D13
        return MacStrings.macos_screenshots_cannotread(count)
    }

    private static func grouped(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: count)) ?? String(count)
    }
}
