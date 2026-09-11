// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Foundation
import Testing
@testable import solstone

@Suite("SolstoneResourceImageTests")
struct SolstoneResourceImageTests {
    @Test func loadAppIconICNS() throws {
        let image = try SolstoneResourceImage.load(
            named: "AppIcon",
            in: SolstoneResources.bundle,
            inDirectory: "Resources",
            types: ["icns"],
            isTemplate: false
        )
        #expect(!image.representations.isEmpty)
        #expect(!image.isTemplate)
    }

    @Test func loadTemplatePDF() throws {
        let image = try SolstoneResourceImage.load(
            named: "sol-ring-template",
            in: SolstoneResources.bundle,
            inDirectory: "Resources",
            types: ["pdf"],
            isTemplate: true
        )
        #expect(!image.representations.isEmpty)
        #expect(image.isTemplate)
    }

    @Test func loadPNGFixture() throws {
        let image = try SolstoneResourceImage.load(
            named: "loader-fixture",
            in: Bundle.module,
            inDirectory: "Fixtures",
            types: ["png"],
            isTemplate: false
        )
        #expect(!image.representations.isEmpty)
        #expect(!image.isTemplate)
    }

    @Test func missingAssetReturnsNotFound() {
        #expect {
            try SolstoneResourceImage.load(
                named: "nonexistent-asset-name-12345",
                in: SolstoneResources.bundle,
                inDirectory: "Resources"
            )
        } throws: { error in
            guard case .notFound(let name, let dir, let types) = error as? SolstoneResourceImage.LoadError else {
                return false
            }
            return name == "nonexistent-asset-name-12345" && dir == "Resources" && types == ["icns", "pdf", "png"]
        }
    }

    @Test func malformedAssetFails() {
        #expect {
            try SolstoneResourceImage.load(
                named: "loader-malformed",
                in: Bundle.module,
                inDirectory: "Fixtures",
                types: ["png"]
            )
        } throws: { error in
            guard let loadError = error as? SolstoneResourceImage.LoadError else { return false }
            switch loadError {
            case .unreadable, .emptyRepresentation:
                return true
            default:
                return false
            }
        }
    }

    @Test func unsupportedTypeReturnsError() {
        #expect {
            try SolstoneResourceImage.load(
                named: "loader-unsupported",
                in: Bundle.module,
                inDirectory: "Fixtures",
                types: ["txt"]
            )
        } throws: { error in
            guard case .unsupportedType(let type) = error as? SolstoneResourceImage.LoadError else {
                return false
            }
            return type == "txt"
        }
    }

    @Test func mustLoadSuccess() {
        let image = SolstoneResourceImage.mustLoad(
            named: "sol-ring-template",
            in: SolstoneResources.bundle,
            inDirectory: "Resources",
            isTemplate: true
        )
        #expect(!image.representations.isEmpty)
        #expect(image.isTemplate)
    }

    @Test func defaultTypesLoadAppIcon() throws {
        let image = try SolstoneResourceImage.load(
            named: "AppIcon",
            in: SolstoneResources.bundle,
            inDirectory: "Resources"
        )
        #expect(!image.representations.isEmpty)
        #expect(!image.isTemplate)
    }
}
