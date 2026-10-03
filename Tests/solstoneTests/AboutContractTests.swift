// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Darwin
import Foundation
import SolstoneCore
import Testing
@testable import solstone

@Suite("AboutContract")
struct AboutContractTests {
    private var bundleURL: URL {
        let file = URL(fileURLWithPath: #filePath)
        let root = file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent("vendor/contracts/solstone-core-about/bundle")
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func data(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test func adoptionDigests() throws {
        let adoption = try object(Data(contentsOf: bundleURL.deletingLastPathComponent().appendingPathComponent("adoption.json")))
        #expect(adoption.count == 4)
        #expect(adoption["source_repository"] as? String == "solpbc/solstone-journal")
        #expect(adoption["source_revision"] as? String == "ec1983799b66d3616708851d01803e4f3d6f0a20")
        #expect(adoption["source_path"] as? String == "core/crates/solstone-core-about/bundle")
        #expect(adoption["manifest_sha256"] as? String == "301c1d84616379e11aaf22bb341e524bb4b2317051ea08453db9fdd87c706ab0")

        let manifestData = try Data(contentsOf: bundleURL.appendingPathComponent("manifest.json"))
        #expect(digest(manifestData) == adoption["manifest_sha256"] as? String)
        let manifest = try object(manifestData)
        let artifacts = try #require(manifest["artifacts"] as? [String: String])
        for (path, expected) in artifacts {
            let bytes = try Data(contentsOf: bundleURL.appendingPathComponent(path))
            #expect(digest(bytes) == expected, "Hash mismatch for \(path)")
        }
    }

    @Test func contractFixturesRenderExactly() throws {
        let contract = try object(Data(contentsOf: bundleURL.appendingPathComponent("contract.json")))
        let fixtures = try #require(contract["fixtures"] as? [[String: Any]])
        for fixture in fixtures {
            let version = try #require(fixture["version"] as? String)
            let expected = try #require(fixture["about"] as? String)
            let actual = SolstoneCoreAbout.renderLine(
                name: "journal",
                version: version,
                build: fixture["build"] as? String,
                os: fixture["os"] as? String,
                osVersion: fixture["os_version"] as? String,
                arch: fixture["arch"] as? String
            )
            #expect(actual == expected, "Rendered text: \(actual); expected: \(expected)")
        }
    }

    @Test func resourceDecoderRejectsInvalidEntriesAndKeepsOnlyWhitelistedFields() throws {
        let resources = try object(Data(contentsOf: bundleURL.appendingPathComponent("resources.json")))
        let valid = try #require(resources["valid"] as? [[String: Any]])
        #expect(valid.count == 1)
        let validResource = try #require(SolstoneCoreAbout.decodeResource(try data(valid[0])))
        #expect(validResource.protocolVersion == 1)
        #expect(validResource.version == "1.2.3")
        #expect(validResource.build == nil)
        #expect(validResource.os == "ubuntu")
        #expect(validResource.osVersion == "24.04")
        #expect(validResource.arch == "x86_64")
        #expect(validResource.about == "journal 1.2.3 · ubuntu 24.04 · x86_64")

        let invalid = try #require(resources["invalid"] as? [[String: Any]])
        for entry in invalid {
            #expect(SolstoneCoreAbout.decodeResource(try data(entry)) == nil)
        }

        var future = valid[0]
        future["private_model"] = "PRIVATE MODEL"
        #expect(SolstoneCoreAbout.decodeResource(try data(future)) == validResource)
    }

    @Test func buildIsOmittedForNonMacOSAndVPrefixesAreRenderingOnly() throws {
        let value: [String: Any] = [
            "protocol_version": 1,
            "version": "vv1.2.3",
            "build": "source-hash",
            "os": "linux",
            "os_version": "6.11.0",
            "arch": "riscv64",
            "about": "journal 1.2.3 · linux 6.11.0 · riscv64"
        ]
        let decoded = try #require(SolstoneCoreAbout.decodeResource(try data(value)))
        #expect(decoded.version == "vv1.2.3")
        #expect(decoded.build == nil)
        #expect(SolstoneCoreAbout.renderLine(name: "journal", version: "vvv2.0", build: "67", os: "macos") == "journal 2.0 (67) · macos")
    }

    @Test func nativeArchAndNumericOSRules() {
        #expect(SolstoneCoreAbout.nativeMacOSArch(procTranslated: .success(1), hwMachine: "x86_64") == "arm64")
        #expect(SolstoneCoreAbout.nativeMacOSArch(procTranslated: .success(1), hwMachine: nil) == "arm64")
        #expect(SolstoneCoreAbout.nativeMacOSArch(procTranslated: .success(0), hwMachine: "ARM64") == "arm64")
        #expect(SolstoneCoreAbout.nativeMacOSArch(procTranslated: .success(0), hwMachine: "amd64") == "x86_64")
        #expect(SolstoneCoreAbout.nativeMacOSArch(procTranslated: .failure(ENOENT), hwMachine: "x64") == "x86_64")
        #expect(SolstoneCoreAbout.nativeMacOSArch(procTranslated: .failure(ENOENT), hwMachine: "aarch64") == "arm64")
        #expect(SolstoneCoreAbout.nativeMacOSArch(procTranslated: .failure(EPERM), hwMachine: "arm64") == nil)
        #expect(SolstoneCoreAbout.nativeMacOSArch(procTranslated: .success(2), hwMachine: "arm64") == nil)
        #expect(SolstoneCoreAbout.nativeMacOSArch(procTranslated: .success(0), hwMachine: nil) == nil)
        #expect(SolstoneCoreAbout.numericOSVersion(.init(majorVersion: 15, minorVersion: 6, patchVersion: 0)) == "15.6")
        #expect(SolstoneCoreAbout.numericOSVersion(.init(majorVersion: 26, minorVersion: 0, patchVersion: 0)) == "26.0")
        #expect(SolstoneCoreAbout.numericOSVersion(.init(majorVersion: 15, minorVersion: 6, patchVersion: 1)) == "15.6.1")
    }

    @Test func privateSentinelsDoNotReachLinesReportsOrSnapshots() throws {
        let sentinels = ["PRIVATE-HOST", "/private/PRIVATE-PATH", "PRIVATE-ACCOUNT", "192.0.2.7", "PRIVATE-MODEL"]
        let resources = try object(Data(contentsOf: bundleURL.appendingPathComponent("resources.json")))
        var realResource = try #require((resources["valid"] as? [[String: Any]])?.first)
        realResource["hostname"] = sentinels[0]
        realResource["path"] = sentinels[1]
        realResource["account"] = sentinels[2]
        realResource["address"] = sentinels[3]
        realResource["model"] = sentinels[4]
        let journal = try #require(SolstoneCoreAbout.decodeResource(try data(realResource)))
        let line = SolstoneCoreAbout.renderLine(
            name: "solstone macos app",
            version: "2.0.0",
            build: "67",
            os: "macos",
            osVersion: "15.6",
            arch: "arm64"
        )
        let aboutBlock = line + "\n" + journal.about
        let reportURL = SupportReportURL.make(version: "2.0.0", build: "67", osVersion: "15.6", state: "paused", recent: nil, about: aboutBlock)
        let snapshot = try SolstoneCoreAbout.nativeSnapshot(
            os: "macos", osVersion: "15.6", arch: "arm64", journalVersion: journal.version,
            journalBuild: journal.build, journalOS: journal.os, journalOSVersion: journal.osVersion,
            journalArch: journal.arch,
            journalCurrent: true, versionObservedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ).object()
        let output = aboutBlock + reportURL.absoluteString + String(describing: snapshot)
        for sentinel in sentinels {
            #expect(!output.contains(sentinel))
        }
    }
}
