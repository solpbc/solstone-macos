// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Owner-visible copy for the folders source, backed by `i18n/catalog/source/en-US.ftl`.
enum FolderSourceCopy {
    static var label: String { MacStrings.macos_folders_label() }
    static var addFolder: String { MacStrings.macos_folders_addfolder() }
    static var chooseFolder: String { MacStrings.macos_folders_choosefolder() }
    static var intro: String { MacStrings.macos_folders_intro() }
    static var unpaired: String { MacStrings.macos_folders_unpaired() }
    static var journalUpdate: String { MacStrings.macos_folders_journalupdate() }
    static var pausedFolder: String { MacStrings.macos_folders_pausedfolder() }
    static var pausedMac: String { MacStrings.macos_folders_pausedmac() }
    static var offReason: String { MacStrings.macos_folders_off() }
    static var stays: String { MacStrings.macos_folders_stays() }
    static var otherOn: String { MacStrings.macos_folders_otheron() }
    static var otherOff: String { MacStrings.macos_folders_otheroff() }
    static var remove: String { MacStrings.macos_folders_remove() }
    static var overlapBody: String { MacStrings.macos_folders_overlapbody() }
    static var overlapChoose: String { MacStrings.macos_folders_overlapchoose() }
    static var overlapOverride: String { MacStrings.macos_folders_overlapoverride() }
    static var whatComesIn: String { MacStrings.macos_folders_whatcomesin() }
    static var kindNotes: String { MacStrings.macos_folders_kind_notes() }
    static var kindNotesDesc: String { MacStrings.macos_folders_kind_notes_desc() }
    static var kindDocuments: String { MacStrings.macos_folders_kind_documents() }
    static var kindDocumentsDesc: String { MacStrings.macos_folders_kind_documents_desc() }
    static var kindTranscripts: String { MacStrings.macos_folders_kind_transcripts() }
    static var kindTranscriptsDesc: String { MacStrings.macos_folders_kind_transcripts_desc() }
    static var kindScreenshots: String { MacStrings.macos_folders_kind_screenshots() }
    static var kindScreenshotsDesc: String { MacStrings.macos_folders_kind_screenshots_desc() }
    static var kindPhotos: String { MacStrings.macos_folders_kind_photos() }
    static var kindPhotosDesc: String { MacStrings.macos_folders_kind_photos_desc() }
    static var kindOther: String { MacStrings.macos_folders_kind_other() }
    static var kindOtherDesc: String { MacStrings.macos_folders_kind_other_desc() }
    static var chooseAtLeastOne: String { MacStrings.macos_folders_chooseatleastone() }
    static var kindsGoingForward: String { MacStrings.macos_folders_kindsgoingforward() }
    static var facetHeading: String { MacStrings.macos_folders_facetheading() }
    static var facetNone: String { MacStrings.macos_folders_facetnone() }
    static var facetHelpNone: String { MacStrings.macos_folders_facethelpnone() }
    static var facetUnpaired: String { MacStrings.macos_folders_facetunpaired() }
    static var facetOffline: String { MacStrings.macos_folders_facetoffline() }
    static var previewHeading: String { MacStrings.macos_folders_preview() }
    static var checkingFolder: String { MacStrings.macos_folders_checkingfolder() }
    static var previewZero: String { MacStrings.macos_folders_previewzero() }
    static var estHeading: String { MacStrings.macos_folders_estheading() }
    static var estGloss: String { MacStrings.macos_folders_estgloss() }
    static var estUnpaired: String { MacStrings.macos_folders_estunpaired() }
    static var estOffline: String { MacStrings.macos_folders_estoffline() }
    static var scopeNote: String { MacStrings.macos_folders_scopenote() }
    static var nothingUntilConfirm: String { MacStrings.macos_folders_nothinguntilconfirm() }
    static var noRepeat: String { MacStrings.macos_folders_norepeat() }
    static var previewFailed: String { MacStrings.macos_folders_previewfailed() }
    static var bringInOlder: String { MacStrings.macos_folders_bringinolder() }
    static var backfillStatus: String { MacStrings.macos_folders_backfillstatus() }
    static var icloudNote: String { MacStrings.macos_folders_icloudnote() }
    static var refusedLocal: String { MacStrings.macos_folders_refused() }
    static var refusedStorage: String { MacStrings.macos_folders_refusedstorage() }

    // Locked shared conventions
    static var pause: String { MacStrings.macos_desktop_shared_setup_wizardpausefailure() }
    static var resume: String { MacStrings.macos_desktop_shared_setup_wizardpausefailure2() }
    static var cancel: String { MacStrings.macos_desktop_shared_setup_cancel() }
    static var tryAgain: String { MacStrings.macos_desktop_shared_copy_tryagain() }
    static var openSystemSettings: String { ScreenshotCopy.openSystemSettings }
    static var fromBeforeToday: String { ScreenshotCopy.fromBeforeToday }
    static var startFromToday: String { MacStrings.macos_screenshot_startfromtoday() }
    static var folderLabel: String { ScreenshotCopy.folderLabel }
    static var lastChecked: String { ScreenshotCopy.lastChecked }
    static var waitingLabel: String { ScreenshotCopy.waitingLabel }
    static var moreAboutThis: String { ScreenshotCopy.moreAboutThis }
    static var soFar: String { ScreenshotCopy.soFar }
    static var lastTakenIn: String { ScreenshotCopy.lastTakenIn }

    static func oneIntro(_ folder: String) -> String { MacStrings.macos_folders_oneintro(folder) }
    static func two(_ first: String, _ second: String) -> String { MacStrings.macos_folders_two(first, second) }
    static func many(_ count: Int) -> String { MacStrings.macos_folders_many(count) }
    static func split(on: Int, paused: Int) -> String {
        MacStrings.macos_folders_split(MacStrings.number(on), MacStrings.number(paused))
    }
    static func tileProgress(folder: String, done: Int, total: Int) -> String {
        MacStrings.macos_folders_tileprogress(folder, MacStrings.number(done), MacStrings.number(total))
    }
    static func pageProgress(done: Int, total: Int) -> String {
        MacStrings.macos_folders_pageprogress(MacStrings.number(done), MacStrings.number(total))
    }
    static func waiting(_ count: Int) -> String { MacStrings.macos_folders_waiting(MacStrings.number(count)) }
    static func waitingFolder(_ folder: String, count: Int) -> String {
        MacStrings.macos_folders_waitingfolder(folder, MacStrings.number(count))
    }
    static func finishSetup(_ folder: String) -> String { MacStrings.macos_folders_finishsetup(folder) }
    static func needAttentionMany(_ count: Int) -> String { MacStrings.macos_folders_needattentionmany(count) }
    static func alreadyAdded(_ folder: String) -> String { MacStrings.macos_folders_alreadyadded(folder) }
    static func openFolder(_ folder: String) -> String { MacStrings.macos_folders_openfolder(folder) }
    static func removeHeading(_ folder: String) -> String { MacStrings.macos_folders_removeheading(folder) }
    static func removeBody(_ folder: String) -> String { MacStrings.macos_folders_removebody(folder) }
    static func overlapHeading(_ other: String) -> String { MacStrings.macos_folders_overlapheading(other) }
    static func overlapFact(_ other: String) -> String { MacStrings.macos_folders_overlapfact(other) }
    static func overlapObsidian(_ name: String) -> String { MacStrings.macos_folders_overlapobsidian(name) }
    static func overlapScreenshots(_ name: String) -> String { MacStrings.macos_folders_overlapscreenshots(name) }
    static func overlapFolder(_ name: String) -> String { MacStrings.macos_folders_overlapfolder(name) }
    static func facetHelpSetup(_ facet: String) -> String { MacStrings.macos_folders_facethelpsetup(facet) }
    static func facetHelpActive(_ facet: String) -> String { MacStrings.macos_folders_facethelpactive(facet) }
    static func previewSpan(count: Int, start: String, end: String) -> String {
        MacStrings.macos_folders_previewspan(count, start, end)
    }
    static func previewCount(_ count: Int) -> String { MacStrings.macos_folders_previewcount(count) }
    static func previewBreakdown(contentItems: Int, contentBytes: Int64, metadataOnlyItems: Int) -> String? {
        let size = FolderSourceClassify.formatBytes(contentBytes)
        if contentItems > 0 && metadataOnlyItems > 0 {
            return MacStrings.macos_folders_previewboth(
                MacStrings.macos_folders_previewcontentonly(contentItems, size),
                MacStrings.macos_folders_previewmetaonly(metadataOnlyItems)
            )
        }
        if contentItems > 0 {
            return MacStrings.macos_folders_previewcontentonly(contentItems, size)
        }
        if metadataOnlyItems > 0 {
            return MacStrings.macos_folders_previewmetaonly(metadataOnlyItems)
        }
        return nil
    }
    static func estimateLine(segments: Int, days: Int, thoughts: Int) -> String {
        MacStrings.macos_folders_estvalues(
            MacStrings.macos_folders_estsegments(segments),
            MacStrings.macos_folders_estdays(days),
            MacStrings.macos_folders_estthoughts(thoughts)
        )
    }
    static func confirmTitle(span: FolderSpan, count: Int) -> String {
        if span == .fromToday || count <= 0 {
            return startFromToday
        }
        return MacStrings.macos_folders_bringin(count)
    }
    static func missing(_ folder: String) -> String { MacStrings.macos_folders_missing(folder) }
    static func unreadable(_ folder: String) -> String { MacStrings.macos_folders_unreadable(folder) }
    static func accessOff(_ folder: String) -> String { MacStrings.macos_folders_accessoff(folder) }
    static func cantRead(_ count: Int) -> String? {
        count > 0 ? MacStrings.macos_folders_cantread(count) : nil
    }
    static func fallback(_ count: Int) -> String? {
        count > 0 ? MacStrings.macos_folders_fallback(count) : nil
    }
    static func itemCount(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        let display = formatter.string(from: NSNumber(value: count)) ?? String(count)
        return MacStrings.macos_desktopshellmodel_items_plural(count, display)
    }
}
