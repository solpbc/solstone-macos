// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import solstone

@Suite("Server segment proof")
struct ServerSegmentProofTests {
    @Test func presentAndRelocatedMatchingFilesAreHeld() {
        let segment = ServerSegmentInfo(
            key: "120000_300",
            originalKey: nil,
            files: [
                ServerFileInfo(
                    name: "audio.m4a",
                    submittedName: "120000_300_audio.m4a",
                    sha256: "aaa",
                    size: 3,
                    status: .present,
                    currentPath: nil
                ),
                ServerFileInfo(
                    name: "display_1_screen.mp4",
                    submittedName: "120000_300_display_1_screen.mp4",
                    sha256: "bbb",
                    size: 3,
                    status: .relocated,
                    currentPath: "20260703/120000_300/display_1_screen.mp4"
                ),
            ]
        )

        let verdict = proveServerHoldsUploadFiles(
            localSHAByFilename: [
                "120000_300_audio.m4a": "aaa",
                "120000_300_display_1_screen.mp4": "bbb",
            ],
            serverSegment: segment
        )

        #expect(verdict.isHeld)
    }

    @Test func adversarialListingsAreNotHeld() {
        #expect(!proveServerHoldsUploadFiles(localSHAByFilename: [:], serverSegment: nil).isHeld)

        let crossed = ServerSegmentInfo(
            key: "120000_300",
            originalKey: nil,
            files: [
                ServerFileInfo(name: "a.mp4", submittedName: "a.mp4", sha256: "bbb", size: 3, status: .present, currentPath: nil),
                ServerFileInfo(name: "b.m4a", submittedName: "b.m4a", sha256: "aaa", size: 3, status: .present, currentPath: nil),
            ]
        )
        #expect(!proveServerHoldsUploadFiles(
            localSHAByFilename: ["a.mp4": "aaa", "b.m4a": "bbb"],
            serverSegment: crossed
        ).isHeld)

        let emptySHA = ServerSegmentInfo(
            key: "120000_300",
            originalKey: nil,
            files: [
                ServerFileInfo(name: "a.mp4", submittedName: "a.mp4", sha256: "", size: 3, status: .present, currentPath: nil),
            ]
        )
        #expect(!proveServerHoldsUploadFiles(localSHAByFilename: ["a.mp4": "aaa"], serverSegment: emptySHA).isHeld)

        let missingStatus = ServerSegmentInfo(
            key: "120000_300",
            originalKey: nil,
            files: [
                ServerFileInfo(name: "a.mp4", submittedName: "a.mp4", sha256: "aaa", size: 3, status: .missing, currentPath: nil),
            ]
        )
        #expect(!proveServerHoldsUploadFiles(localSHAByFilename: ["a.mp4": "aaa"], serverSegment: missingStatus).isHeld)

        let unknownStatus = ServerSegmentInfo(
            key: "120000_300",
            originalKey: nil,
            files: [
                ServerFileInfo(name: "a.mp4", submittedName: "a.mp4", sha256: "aaa", size: 3, status: .unknown, currentPath: nil),
            ]
        )
        #expect(!proveServerHoldsUploadFiles(localSHAByFilename: ["a.mp4": "aaa"], serverSegment: unknownStatus).isHeld)
    }

    @Test func localOnlyExtrasDoNotBlockHeldSegment() {
        let segment = ServerSegmentInfo(key: "120000_300", originalKey: nil, files: [])

        let verdict = proveServerHoldsUploadFiles(localSHAByFilename: [:], serverSegment: segment)

        #expect(verdict.isHeld)
    }
}
