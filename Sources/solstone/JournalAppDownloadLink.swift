// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

/// The first step when solstone can't install the journal app itself: the
/// owner downloads it, drags it into Applications, then tries again.
struct JournalAppDownloadLink: View {
    static let destination = URL(string: "https://solstone.app/download/journal")!

    var body: some View {
        Link(UICopy.JOURNAL_APP_DOWNLOAD, destination: Self.destination)
            .font(.caption)
            .accessibilityIdentifier(AXID.Settings.journalAppDownload)
    }
}
