// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import journal

@Suite("JournalDevicesCopy")
struct JournalDevicesCopyTests {
    @Test func constantsMatchPinnedCopy() {
        #expect(DevicesCopy.paneTitle == "devices")
        #expect(DevicesCopy.yourDevicesHeader == "your devices")
        #expect(DevicesCopy.peerJournalsHeader == "peer journals")
        #expect(DevicesCopy.loading == "loading devices...")
        #expect(DevicesCopy.emptyTitle == "no devices yet")
        #expect(DevicesCopy.emptyBody == "add a device and it joins your journal.")
        #expect(DevicesCopy.notRunningTitle == "journal is not running")
        #expect(DevicesCopy.notRunningBody == "start the journal, then try again.")
        #expect(DevicesCopy.notReadyTitle == "devices are not ready")
        #expect(DevicesCopy.notReadyBody == "finish setting up your journal, then try again.")
        #expect(DevicesCopy.tryAgain == "try again")
        #expect(DevicesCopy.addDevice == "add a device")
        #expect(DevicesCopy.unnamedDevice == "unnamed device")
        #expect(DevicesCopy.unnamedJournal == "unnamed journal")
        #expect(DevicesCopy.renamePlaceholder == "device name")
        #expect(DevicesCopy.renameSave == "save")
        #expect(DevicesCopy.renameRequired == "enter a name")
        #expect(DevicesCopy.renameFailed == "couldn't rename this device")
        #expect(DevicesCopy.remove == "remove")
        #expect(DevicesCopy.revokeFailed == "couldn't remove this device")
        #expect(DevicesCopy.cancel == "cancel")
        #expect(DevicesCopy.pairingTitle == "add a device")
        #expect(DevicesCopy.pairingOpening == "opening pairing...")
        #expect(DevicesCopy.pairingInstructions == "scan this code or open the link on the device you want to add.")
        #expect(DevicesCopy.pairingLinkLabel == "pairing link")
        #expect(DevicesCopy.copyLink == "copy link")
        #expect(DevicesCopy.copied == "copied ✓")
        #expect(DevicesCopy.pairingCode == "pairing code")
        #expect(DevicesCopy.linkExpiredTitle == "link expired")
        #expect(DevicesCopy.linkExpiredBody == "open a fresh link to add a device.")
        #expect(DevicesCopy.openFreshLink == "open a fresh link")
        #expect(DevicesCopy.pairingFailedTitle == "couldn't open pairing")
        #expect(DevicesCopy.close == "close")
        #expect(DevicesCopy.revokeTitle("laptop") == "remove laptop?")
        #expect(
            DevicesCopy.revokeBody("laptop", detail: "local · never connected")
                == "laptop loses access to your journal. you can add it again later.\nlocal · never connected"
        )
        #expect(DevicesCopy.countdown(seconds: 65) == "expires in 1:05")
        #expect(DevicesCopy.countdown(seconds: -1) == "expires in 0:00")
    }

    @Test func devicesCopyAvoidsForbiddenTokensAndStartsLowercase() {
        let copies = [
            DevicesCopy.paneTitle,
            DevicesCopy.yourDevicesHeader,
            DevicesCopy.peerJournalsHeader,
            DevicesCopy.loading,
            DevicesCopy.emptyTitle,
            DevicesCopy.emptyBody,
            DevicesCopy.notRunningTitle,
            DevicesCopy.notRunningBody,
            DevicesCopy.notReadyTitle,
            DevicesCopy.notReadyBody,
            DevicesCopy.tryAgain,
            DevicesCopy.addDevice,
            DevicesCopy.unnamedDevice,
            DevicesCopy.unnamedJournal,
            DevicesCopy.renamePlaceholder,
            DevicesCopy.renameSave,
            DevicesCopy.renameRequired,
            DevicesCopy.renameFailed,
            DevicesCopy.remove,
            DevicesCopy.revokeFailed,
            DevicesCopy.cancel,
            DevicesCopy.pairingTitle,
            DevicesCopy.pairingOpening,
            DevicesCopy.pairingInstructions,
            DevicesCopy.pairingLinkLabel,
            DevicesCopy.copyLink,
            DevicesCopy.copied,
            DevicesCopy.pairingCode,
            DevicesCopy.linkExpiredTitle,
            DevicesCopy.linkExpiredBody,
            DevicesCopy.openFreshLink,
            DevicesCopy.pairingFailedTitle,
            DevicesCopy.close,
            DevicesCopy.revokeTitle("laptop"),
            DevicesCopy.revokeBody("laptop", detail: "local · never connected"),
            DevicesCopy.countdown(seconds: 65),
        ]
        let forbidden = [
            "observer", "observers", "client", "clients", "watch", "capture",
            "record", "monitor", "track", "collect",
        ]

        for copy in copies {
            if let first = copy.unicodeScalars.first {
                #expect(CharacterSet.lowercaseLetters.contains(first))
            } else {
                Issue.record("expected non-empty copy")
            }
            let words = Set(copy.lowercased().split { !$0.isLetter }.map(String.init))
            for token in forbidden {
                #expect(!words.contains(token))
            }
        }
    }
}
