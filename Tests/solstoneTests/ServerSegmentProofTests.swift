// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import solstone

@Suite("Server segment proof")
struct ServerSegmentProofTests {
    @Test func retiredRelocatedStatusIsNotHeld() {
        let segment = ServerSegmentInfo(
            key: "120000_300",
            originalKey: nil,
            files: [
                ServerFileInfo(
                    name: "audio.m4a",
                    submittedName: "120000_300_audio.m4a",
                    sha256: "aaa",
                    size: 3,
                    status: .present
                ),
                ServerFileInfo(
                    name: "display_1_screen.mp4",
                    submittedName: "120000_300_display_1_screen.mp4",
                    sha256: "bbb",
                    size: 3,
                    status: .outOfContract("relocated")
                ),
            ]
        )

        let verdict = proveServerHoldsUploadFiles(
            localFilesByFilename: [
                "120000_300_audio.m4a": LocalUploadFileProof(sha256: "aaa", size: 3),
                "120000_300_display_1_screen.mp4": LocalUploadFileProof(sha256: "bbb", size: 3),
            ],
            serverSegment: segment
        )

        #expect(!verdict.isHeld)
    }

    @Test func processedFileWithMismatchedSHAIsNotHeld() {
        let segment = ServerSegmentInfo(
            key: "120000_300",
            originalKey: nil,
            files: [
                ServerFileInfo(
                    name: "audio.m4a",
                    submittedName: "120000_300_audio.m4a",
                    sha256: "server-sha",
                    size: 3,
                    status: .processed
                ),
            ]
        )

        let verdict = proveServerHoldsUploadFiles(
            localFilesByFilename: ["120000_300_audio.m4a": LocalUploadFileProof(sha256: "local-sha", size: 3)],
            serverSegment: segment
        )

        #expect(!verdict.isHeld)
        #expect(verdict.reason.contains("sha mismatch"))
    }

    @Test func presentAndProcessedMatchingFilesAreHeld() {
        let segment = ServerSegmentInfo(
            key: "120000_300",
            originalKey: nil,
            files: [
                ServerFileInfo(
                    name: "display_1_screen.mp4",
                    submittedName: "120000_300_display_1_screen.mp4",
                    sha256: "video-sha",
                    size: 3,
                    status: .present
                ),
                ServerFileInfo(
                    name: "audio.m4a",
                    submittedName: "120000_300_audio.m4a",
                    sha256: "audio-sha",
                    size: 3,
                    status: .processed
                ),
            ]
        )

        let verdict = proveServerHoldsUploadFiles(
            localFilesByFilename: [
                "120000_300_display_1_screen.mp4": LocalUploadFileProof(sha256: "video-sha", size: 3),
                "120000_300_audio.m4a": LocalUploadFileProof(sha256: "audio-sha", size: 3),
            ],
            serverSegment: segment
        )

        #expect(verdict.isHeld)
    }

    @Test func adversarialListingsAreNotHeld() {
        #expect(!proveServerHoldsUploadFiles(localFilesByFilename: [:], serverSegment: nil).isHeld)

        let crossed = ServerSegmentInfo(
            key: "120000_300",
            originalKey: nil,
            files: [
                ServerFileInfo(name: "a.mp4", submittedName: "a.mp4", sha256: "bbb", size: 3, status: .present),
                ServerFileInfo(name: "b.m4a", submittedName: "b.m4a", sha256: "aaa", size: 3, status: .present),
            ]
        )
        #expect(!proveServerHoldsUploadFiles(
            localFilesByFilename: [
                "a.mp4": LocalUploadFileProof(sha256: "aaa", size: 3),
                "b.m4a": LocalUploadFileProof(sha256: "bbb", size: 3),
            ],
            serverSegment: crossed
        ).isHeld)

        let emptySHA = ServerSegmentInfo(
            key: "120000_300",
            originalKey: nil,
            files: [
                ServerFileInfo(name: "a.mp4", submittedName: "a.mp4", sha256: "", size: 3, status: .present),
            ]
        )
        #expect(!proveServerHoldsUploadFiles(localFilesByFilename: ["a.mp4": LocalUploadFileProof(sha256: "aaa", size: 3)], serverSegment: emptySHA).isHeld)

        let missingStatus = ServerSegmentInfo(
            key: "120000_300",
            originalKey: nil,
            files: [
                ServerFileInfo(name: "a.mp4", submittedName: "a.mp4", sha256: "aaa", size: 3, status: .missing),
            ]
        )
        #expect(!proveServerHoldsUploadFiles(localFilesByFilename: ["a.mp4": LocalUploadFileProof(sha256: "aaa", size: 3)], serverSegment: missingStatus).isHeld)

        let unknownStatus = ServerSegmentInfo(
            key: "120000_300",
            originalKey: nil,
            files: [
                ServerFileInfo(name: "a.mp4", submittedName: "a.mp4", sha256: "aaa", size: 3, status: .outOfContract("unknown")),
            ]
        )
        #expect(!proveServerHoldsUploadFiles(localFilesByFilename: ["a.mp4": LocalUploadFileProof(sha256: "aaa", size: 3)], serverSegment: unknownStatus).isHeld)
    }

    @Test func emptyLocalFileSetIsNotHeld() {
        let segment = ServerSegmentInfo(key: "120000_300", originalKey: nil, files: [])

        let verdict = proveServerHoldsUploadFiles(localFilesByFilename: [:], serverSegment: segment)

        #expect(!verdict.isHeld)
    }
}
