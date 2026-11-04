// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import JournalMarkKit
import SwiftUI

/// The words a notice shows for its place.
struct UnknownJournalNoticeCopy: Equatable {
    let row: String
    let body: String

    init(site: UnknownJournalSite) {
        switch site {
        case .address(let address):
            row = UICopy.unknownJournalRow(address: address)
            body = UICopy.unknownJournalBody(address: address)
        case .relay:
            row = UICopy.UNKNOWN_JOURNAL_ROW_RELAY
            body = UICopy.UNKNOWN_JOURNAL_BODY_RELAY
        }
    }

    static func caption(for whatAnswered: UnknownJournalWhatAnswered) -> String {
        switch whatAnswered {
        case .notPresented:
            return UICopy.UNKNOWN_JOURNAL_CAPTION_NOT_PRESENTED
        case .deriving, .claimed, .claimedUnavailable:
            return UICopy.UNKNOWN_JOURNAL_CAPTION_CLAIMED
        }
    }
}

/// One row per place something other than the paired journal answered, address first, each with
/// its own details. Never collapsed into a summary, because a client can't tell whether two
/// sightings share a cause.
struct UnknownJournalNoticeList: View {
    let notices: [UnknownJournalNotice]
    let yourJournal: UnknownJournalYourMark
    var pairAgainDisabled = false
    var initiallyExpanded: Set<UnknownJournalSite> = []
    let onPairAgain: @MainActor () -> Void

    var body: some View {
        if !notices.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(notices) { notice in
                    UnknownJournalNoticeRow(
                        notice: notice,
                        yourJournal: yourJournal,
                        pairAgainDisabled: pairAgainDisabled,
                        isExpanded: initiallyExpanded.contains(notice.site),
                        onPairAgain: onPairAgain
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AXID.Settings.Service.unknownJournalList)
        }
    }
}

private struct UnknownJournalNoticeRow: View {
    let notice: UnknownJournalNotice
    let yourJournal: UnknownJournalYourMark
    let pairAgainDisabled: Bool
    @State var isExpanded: Bool
    let onPairAgain: @MainActor () -> Void

    private var copy: UnknownJournalNoticeCopy {
        UnknownJournalNoticeCopy(site: notice.site)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(copy.row)
                .font(.callout.weight(.medium))
                .textSelection(.enabled)
                .accessibilityIdentifier(AXID.Settings.Service.unknownJournalRow(notice.site.axKey))
            DisclosureGroup(isExpanded: $isExpanded) {
                detail
                    .padding(.top, 8)
            } label: {
                Text(UICopy.UNKNOWN_JOURNAL_VIEW_DETAILS)
                    .font(.callout)
            }
            .accessibilityIdentifier(AXID.Settings.Service.unknownJournalExpand(notice.site.axKey))
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(UICopy.UNKNOWN_JOURNAL_HEADING)
                .font(.headline)
            Text(copy.body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(UICopy.UNKNOWN_JOURNAL_LABEL_WHAT_ANSWERED)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    whatAnsweredSlot
                    Text(UnknownJournalNoticeCopy.caption(for: notice.whatAnswered))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AXID.Settings.Service.unknownJournalWhatAnswered(notice.site.axKey))

                VStack(alignment: .leading, spacing: 6) {
                    Text(UICopy.UNKNOWN_JOURNAL_LABEL_YOUR_JOURNAL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    yourJournalSlot
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AXID.Settings.Service.unknownJournalYourJournal(notice.site.axKey))
            }
            Button("re-link") {
                onPairAgain()
            }
            .disabled(pairAgainDisabled)
            .accessibilityIdentifier(AXID.Settings.Service.unknownJournalPairAgain(notice.site.axKey))
        }
        .accessibilityIdentifier(AXID.Settings.Service.unknownJournalDetail(notice.site.axKey))
    }

    @ViewBuilder
    private var whatAnsweredSlot: some View {
        switch notice.whatAnswered {
        case .notPresented:
            JournalMarkNotPresentedView()
        case .deriving:
            derivingSlot
        case .claimed(let mark):
            JournalMarkView(mark: mark)
        case .claimedUnavailable:
            // This slot isn't the owner's journal, so it doesn't speak as that surface does.
            JournalMarkUnavailableView(accessibleName: JournalMarkUnavailable.words.joined(separator: " "))
        }
    }

    @ViewBuilder
    private var yourJournalSlot: some View {
        switch yourJournal {
        case .deriving:
            derivingSlot
        case .mark(let mark):
            JournalMarkView(mark: mark)
        case .unavailable:
            JournalMarkUnavailableView()
        }
    }

    private var derivingSlot: some View {
        ProgressView()
            .controlSize(.small)
            .frame(width: 180, height: 120)
    }
}
