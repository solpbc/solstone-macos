// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

enum DevicesCopy {
    static let paneTitle = "devices"
    static let yourDevicesHeader = "your devices"
    static let peerJournalsHeader = "peer journals"
    static let loading = "loading devices..."
    static let emptyTitle = "no devices yet"
    static let emptyBody = "add a device and it joins your journal."
    static let notRunningTitle = "journal is not running"
    static let notRunningBody = "start the journal, then try again."
    static let notReadyTitle = "devices are not ready"
    static let notReadyBody = "finish setting up your journal, then try again."
    static let tryAgain = "try again"
    static let addDevice = "add a device"
    static let unnamedDevice = "unnamed device"
    static let unnamedJournal = "unnamed journal"
    static let remove = "remove"
    static let revokeFailed = "couldn't remove this device"
    static let cancel = "cancel"
    static let pairingTitle = "add a device"
    static let pairingOpening = "opening pairing..."
    static let pairingInstructions = "scan this code or open the link on the device you want to add."
    static let pairingLinkLabel = "pairing link"
    static let copyLink = "copy link"
    static let copied = "copied ✓"
    static let pairingCode = "pairing code"
    static let linkExpiredTitle = "link expired"
    static let linkExpiredBody = "open a fresh link to add a device."
    static let openFreshLink = "open a fresh link"
    static let pairingFailedTitle = "couldn't open pairing"
    static let close = "close"

    static func revokeTitle(_ name: String) -> String {
        "remove \(name)?"
    }

    static func revokeBody(_ name: String, detail: String) -> String {
        "\(name) loses access to your journal. you can add it again later.\n\(detail)"
    }

    static func countdown(seconds: Int) -> String {
        let clamped = max(0, seconds)
        return "expires in \(clamped / 60):\(String(format: "%02d", clamped % 60))"
    }
}
