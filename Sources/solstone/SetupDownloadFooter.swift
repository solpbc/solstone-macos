// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct SetupDownloadFooter: View {
    let downloads: SetupDownloads?
    var readFailed = false
    var actionsEnabled = false
    var perform: (SetupDownloadAction) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let downloads {
                row(title: MacStrings.macos_setup_speechrecognition(), job: downloads.speech, action: downloads.speechAction)
                if downloads.showsThinking {
                    row(title: MacStrings.macos_setup_localthinking(), job: downloads.thinking, action: downloads.thinkingAction)
                }
            } else if readFailed {
                Text(MacStrings.macos_setup_downloadprogressisntavailable())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(title: String, job: SetupDownloadJob, action: SetupDownloadAction?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                    Spacer()
                    Text(stateText(job.state))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                if job.state == .downloading {
                    if let fraction = job.fraction {
                        ProgressView(value: fraction).accessibilityLabel(title)
                    } else {
                        ProgressView().controlSize(.small).accessibilityLabel(title)
                    }
                    Text(byteText(job))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            if let action {
                Button(actionLabel(action)) { perform(action) }
                    .controlSize(.small)
                    .disabled(!actionsEnabled)
            }
        }
    }

    private func actionLabel(_ action: SetupDownloadAction) -> String {
        switch action {
        case .cancelThinking: MacStrings.macos_desktop_shared_setup_cancel()
        case .startThinking, .retrySpeech: UICopy.SETUP_TRY_AGAIN
        }
    }

    private func stateText(_ state: SetupDownloadState) -> String {
        switch state {
        case .idle: MacStrings.macos_setup_notstarted()
        case .downloading: MacStrings.macos_setupdownloadfooter_downloading()
        case .complete: MacStrings.macos_setupdownloadfooter_ready()
        case .cancelled: MacStrings.macos_setupdownloadfooter_cancelled()
        case .error: MacStrings.macos_setup_downloadfailed()
        }
    }

    private func byteText(_ job: SetupDownloadJob) -> String {
        let done = ByteCountFormatter.string(fromByteCount: Int64(clamping: job.bytesDone), countStyle: .file)
        guard let total = job.bytesTotal, total > 0 else { return done }
        let totalText = ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .file)
        return "\(done) / \(totalText)"
    }
}
