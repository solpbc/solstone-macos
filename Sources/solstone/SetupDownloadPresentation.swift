// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

enum SetupDownloadPresentation {
    struct Row: Equatable {
        let name: String
        let detail: String?
        let fraction: Double?
        let indeterminate: Bool
        let actionTitle: String?
        let action: SetupDownloadAction?
    }

    static func rows(downloads: SetupDownloads?) -> [Row] {
        guard let downloads else { return [] }
        var result: [Row] = []
        if let speech = row(name: "speech recognition", job: downloads.speech, action: downloads.speechAction) {
            result.append(speech)
        }
        if let thinking = row(name: "local thinking", job: downloads.thinking, action: downloads.thinkingAction) {
            result.append(thinking)
        }
        return result
    }

    private static func row(name: String, job: SetupDownloadJob, action: SetupDownloadAction?) -> Row? {
        let isShown = job.state == .downloading || job.state == .error || action != nil
        guard isShown else { return nil }

        let actionTitle: String? = {
            guard let action else { return nil }
            switch action {
            case .cancelThinking:
                return "cancel"
            case .startThinking, .retrySpeech:
                return UICopy.SETUP_TRY_AGAIN
            }
        }()

        switch job.state {
        case .downloading:
            let done = ByteCountFormatter.string(fromByteCount: Int64(clamping: job.bytesDone), countStyle: .file)
            if let total = job.bytesTotal, total > 0 {
                let totalStr = ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .file)
                return Row(
                    name: name,
                    detail: "\(done) of \(totalStr)",
                    fraction: job.fraction,
                    indeterminate: false,
                    actionTitle: actionTitle,
                    action: action
                )
            } else {
                return Row(
                    name: name,
                    detail: done,
                    fraction: nil,
                    indeterminate: true,
                    actionTitle: actionTitle,
                    action: action
                )
            }
        case .error:
            return Row(
                name: name,
                detail: "download failed.",
                fraction: nil,
                indeterminate: false,
                actionTitle: actionTitle,
                action: action
            )
        case .cancelled:
            return Row(
                name: name,
                detail: nil,
                fraction: nil,
                indeterminate: false,
                actionTitle: actionTitle,
                action: action
            )
        case .idle, .complete:
            return Row(
                name: name,
                detail: nil,
                fraction: nil,
                indeterminate: false,
                actionTitle: actionTitle,
                action: action
            )
        }
    }
}
