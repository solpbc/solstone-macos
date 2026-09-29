// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import CryptoKit
import Foundation
import Testing
@testable import solstone

@Suite("SolstoneNativeBrowserContract")
struct SolstoneNativeBrowserContractTests {
    private var vendorURL: URL {
        let currentFile = URL(fileURLWithPath: #filePath)
        let repoRoot = currentFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repoRoot.appendingPathComponent("vendor")
    }

    @Test func manifestArtifactsAndAdoptionDigests() throws {
        let vURL = vendorURL
        let manifestURL = vURL.appendingPathComponent("contracts/native-browser/manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifestDigest = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()
        #expect(manifestDigest == "fef157d57a561bd72714d049245ede7317821ca790558ca917aef2efb9df4b73")

        guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let artifacts = manifest["artifacts"] as? [String: String] else {
            #expect(Bool(false), "Failed to parse manifest.json")
            return
        }

        #expect(artifacts.count == 28)

        for (relPath, expectedSHA) in artifacts {
            let fileURL = vURL.appendingPathComponent(relPath)
            #expect(FileManager.default.fileExists(atPath: fileURL.path), "Missing artifact: \(relPath)")
            let data = try Data(contentsOf: fileURL)
            let actualSHA = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(actualSHA == expectedSHA, "Hash mismatch for \(relPath)")
        }

        // Check adoption.json against adoption.schema.json
        let adoptionURL = vURL.appendingPathComponent("contracts/native-browser/adoption.json")
        let adoptionData = try Data(contentsOf: adoptionURL)
        guard let adoption = try JSONSerialization.jsonObject(with: adoptionData) as? [String: Any] else {
            #expect(Bool(false), "Failed to parse adoption.json")
            return
        }

        #expect(adoption["bundle_path"] as? String == "contracts/native-browser")
        #expect(adoption["source_revision"] as? String == "0d9a3f513e5ba8c61e7aa068fa5ad5dafc074eab")
        #expect(adoption["bundle_version"] as? String == "1.1.0")
        #expect(adoption["wire_protocol"] as? Int == 1)
        #expect(adoption["manifest_sha256"] as? String == "fef157d57a561bd72714d049245ede7317821ca790558ca917aef2efb9df4b73")
        #expect(adoption["journal_schema_id"] as? String == "solstone-journal-format:browser-jsonl")
        #expect(adoption["journal_schema_sha256"] as? String == "c14e66318587b8fa451ef1363e113885bdd80a41ce680b0c62fcc9033460a2e1")
        #expect(adoption["journal_schema_revision"] as? String == "3b99f1af61d4e82c5c9c3748d90c1242c28c1e5b")
        #expect(adoption.count == 8)
    }

    @Test func projectionMatchesConstantsRsAndAuthority() throws {
        let projection = try BrowserContractProjection(rootURL: vendorURL)

        #expect(projection.bundleVersion == "1.1.0")
        #expect(projection.wireProtocol == 1)
        #expect(projection.caps.extensionToHost == 33554432)
        #expect(projection.caps.hostToExtension == 65536)
        #expect(projection.caps.control == 65536)
        #expect(projection.caps.deltaRecords == 3000)
        #expect(projection.caps.batchIdHex == 32)
        #expect(projection.caps.jsonMaxDepth == 127)

        #expect(projection.policy.file == 50331648)
        #expect(projection.policy.outboxBytes == 67108864)
        #expect(projection.policy.outboxAgeMs == 600000)
        #expect(projection.policy.spoolBytes == 536870912)
        #expect(projection.policy.spoolAgeMs == 604800000)
        #expect(projection.policy.futureSkewMs == 60000)
        #expect(projection.policy.acceptedRetentionMs == 1200000)
        #expect(projection.policy.freshnessMaxMs == 15000)
        #expect(projection.policy.timestampMax == 9007199254740991)

        #expect(projection.prodHosts.host == "app.solstone.browser")
        #expect(projection.prodHosts.chromeId == "eibbeeoifjoabddfmgeggnageolkcnim")
        #expect(projection.prodHosts.edgeId == "eibbeeoifjoabddfmgeggnageolkcnim")
        #expect(projection.prodHosts.firefoxId == "browser@solstone.app")

        #expect(projection.devHosts.host == "app.solstone.browser.dev")
        #expect(projection.devHosts.chromeId == "fgfnkcefedeheoeamppkiiloncfekakf")
        #expect(projection.devHosts.edgeId == "fgfnkcefedeheoeamppkiiloncfekakf")
        #expect(projection.devHosts.firefoxId == "browser.dev@solstone.app")

        #expect(projection.receiptClasses["retryable"]?.sorted() == ["age_policy", "queue_full", "resource_exhausted", "snapshot_required"].sorted())
        #expect(projection.receiptClasses["permanent"]?.sorted() == ["expired_unaccepted", "malformed", "oversize", "stale_generation", "unaccepted_lost"].sorted())
    }

    @Test func previewResourceLookupUsesBundleResources() throws {
        let root = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
            .appendingPathComponent("browser-resource-lookup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vendor = root.appendingPathComponent("Contents/Resources/vendor", isDirectory: true)
        let paths = [
            "contracts/native-browser/authority.json",
            "crates/native-browser-frame/src/constants.rs",
            "contracts/native-browser/envelope.schema.json",
            "contracts/native-browser/browser.schema.json",
            "contracts/native-browser/manifest.json"
        ]
        for path in paths {
            let file = vendor.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: file)
        }
        #expect(BrowserContractProjection.vendorRootURL(bundleURL: root) == vendor)
        try FileManager.default.removeItem(at: vendor.appendingPathComponent("contracts/native-browser/manifest.json"))
        #expect(BrowserContractProjection.vendorRootURL(bundleURL: root) == nil)
    }

    @Test func corpusVectorsValidation() throws {
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let corpusURL = vendorURL.appendingPathComponent("contracts/native-browser/corpus.json")
        let corpusData = try Data(contentsOf: corpusURL)
        guard let corpus = try JSONSerialization.jsonObject(with: corpusData) as? [[String: Any]] else {
            #expect(Bool(false), "Failed to parse corpus.json")
            return
        }

        #expect(corpus.count == 176)

        for v in corpus {
            let id = v["id"] as? String ?? ""
            let direction = v["direction"] as? String ?? "extension_to_host"
            let expect = v["expect"] as? String ?? "accept"
            let expectedCode = v["code"] as? String

            let payloadBytes: Data
            if let rawStr = v["raw"] as? String {
                payloadBytes = Data(rawStr.utf8)
            } else if let payloadStr = v["payload"] as? String {
                payloadBytes = Data(payloadStr.utf8)
            } else {
                #expect(Bool(false), "Vector \(id) has neither raw nor payload")
                continue
            }

            let result = BrowserPayloadDecoder.decode(bytes: payloadBytes, direction: direction, projection: projection)

            if expect == "accept" {
                switch result {
                case .accept:
                    break
                case .refuse(let r):
                    #expect(Bool(false), "Vector \(id) expected accept but got refuse(\(r.code))")
                case .unsupported(let p, let b):
                    #expect(Bool(false), "Vector \(id) expected accept but got unsupported(\(p), \(b))")
                }
            } else if expect == "refuse" {
                switch result {
                case .accept:
                    #expect(Bool(false), "Vector \(id) expected refuse(\(expectedCode ?? "")) but got accept")
                case .refuse(let r):
                    if let expCode = expectedCode {
                        #expect(r.code == expCode, "Vector \(id) code mismatch: expected \(expCode), got \(r.code)")
                    }
                case .unsupported:
                    #expect(Bool(false), "Vector \(id) expected refuse but got unsupported")
                }
            } else if expect == "unsupported" {
                switch result {
                case .unsupported:
                    break
                default:
                    #expect(Bool(false), "Vector \(id) expected unsupported but got \(result)")
                }
            }
        }
    }

    @Test func recipesValidation() throws {
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let recipesURL = vendorURL.appendingPathComponent("contracts/native-browser/recipes.json")
        let recipesData = try Data(contentsOf: recipesURL)
        guard let recipes = try JSONSerialization.jsonObject(with: recipesData) as? [[String: Any]] else {
            #expect(Bool(false), "Failed to parse recipes.json")
            return
        }

        #expect(recipes.count == 6)

        for r in recipes {
            let id = r["id"] as? String ?? ""
            let expectedLen = r["target_length"] as? Int ?? 0
            let expectedSHA = r["sha256"] as? String ?? ""

            let recipeBytes = buildRecipe(id: id, projection: projection)
            #expect(recipeBytes.count == expectedLen, "Recipe \(id) length mismatch")
            let actualSHA = SHA256.hash(data: recipeBytes).map { String(format: "%02x", $0) }.joined()
            #expect(actualSHA == expectedSHA, "Recipe \(id) SHA-256 mismatch")

            let decoded = BrowserPayloadDecoder.decode(
                bytes: recipeBytes,
                direction: "extension_to_host",
                projection: projection
            )
            switch id {
            case "extension_to_host_batch_oversize", "control_payload_oversize":
                if case .refuse(let refusal) = decoded {
                    #expect(refusal.code == "oversize")
                } else {
                    #expect(Bool(false), "Recipe \(id) should refuse oversize")
                }
            case "batch_delta_oversize_3001":
                if case .refuse(let refusal) = decoded {
                    #expect(refusal.code == "too_many_deltas")
                } else {
                    #expect(Bool(false), "Recipe \(id) should refuse too_many_deltas")
                }
            default:
                if case .accept = decoded {
                } else {
                    #expect(Bool(false), "Recipe \(id) should decode")
                }
            }
        }
    }

    @Test func productionDecoderMatchesFrozenContract() throws {
        let projection = try BrowserContractProjection(rootURL: vendorURL)

        func decode(_ json: String, direction: String = "extension_to_host") -> BrowserDecodeResult {
            BrowserPayloadDecoder.decode(bytes: Data(json.utf8), direction: direction, projection: projection)
        }

        if case .refuse(let refusal) = decode(#"{"type":"hello","protocol":9007199254740992,"version":"1","brand":"chrome","inst":"i"}"#) {
            #expect(refusal.code == "bad_number")
        } else {
            #expect(Bool(false), "unsafe protocol integer should be refused")
        }
        if case .accept(.hello) = decode(#"{"type":"hello","protocol":1.0,"version":"1","brand":"chrome","inst":"i"}"#) {
        } else {
            #expect(Bool(false), "1.0 is an integral protocol")
        }
        if case .unsupported = decode(#"{"type":"hello","protocol":1e3,"version":"1","brand":"chrome","inst":"i"}"#) {
        } else {
            #expect(Bool(false), "1e3 is an integral unsupported protocol")
        }
        if case .refuse(let refusal) = decode(#"{"type":"hello","protocol":2.5,"version":"1","brand":"chrome","inst":"i"}"#) {
            #expect(refusal.code == "bad_number")
        } else {
            #expect(Bool(false), "2.5 is not an integer")
        }

        let literal = #"{"type":"batch","destination_generation":"g","inst":"i","batch_id":"0123456789abcdef0123456789abcdef","queued_at_ms":0,"records":[{"t":"segment_start","ts":0,"ctx":"c","title":"\\uD800","blocks":[{"id":"b","text":"x"}]}]}"#
        if case .accept = decode(literal) {
        } else {
            #expect(Bool(false), "escaped backslash before uD800 is literal text")
        }
        let lone = #"{"type":"batch","destination_generation":"g","inst":"i","batch_id":"0123456789abcdef0123456789abcdef","queued_at_ms":0,"records":[{"t":"segment_start","ts":0,"ctx":"c","title":"\uD800","blocks":[{"id":"b","text":"x"}]}]}"#
        if case .refuse(let refusal) = decode(lone) {
            #expect(refusal.code == "lone_surrogate")
        } else {
            #expect(Bool(false), "lone surrogate escape should be refused")
        }

        let longInst = String(repeating: "e\u{0301}", count: 129)
        let longHello = try JSONSerialization.data(withJSONObject: [
            "type": "hello", "protocol": 1, "version": "1", "brand": "chrome", "inst": longInst
        ])
        if case .refuse = BrowserPayloadDecoder.decode(bytes: longHello, direction: "extension_to_host", projection: projection) {
        } else {
            #expect(Bool(false), "unicode scalar length should bound inst")
        }

        let missingText = #"{"type":"batch","destination_generation":"g","inst":"i","batch_id":"0123456789abcdef0123456789abcdef","queued_at_ms":0,"records":[{"t":"segment_start","ts":0,"ctx":"c","blocks":[{"id":"b"}]}]}"#
        if case .refuse(let refusal) = decode(missingText) {
            #expect(refusal.field == "text")
        } else {
            #expect(Bool(false), "block text is required")
        }
        let negativeDepth = #"{"type":"batch","destination_generation":"g","inst":"i","batch_id":"0123456789abcdef0123456789abcdef","queued_at_ms":0,"records":[{"t":"delta","ts":0,"ctx":"c","op":"add","block":{"id":"b","text":"x","depth":-1}}]}"#
        if case .refuse(let refusal) = decode(negativeDepth) {
            #expect(refusal.field == "depth")
        } else {
            #expect(Bool(false), "negative depth should be refused")
        }

        let failedState = #"{"type":"state","capture":"permitted","delivery":"failed","freshness_ms":1000,"destination_generation":"g","period_id":"p"}"#
        if case .refuse(let refusal) = decode(failedState, direction: "host_to_extension") {
            #expect(refusal.field == "failure")
        } else {
            #expect(Bool(false), "failed delivery requires failure")
        }
        let failedWithCause = #"{"type":"state","capture":"permitted","delivery":"failed","failure":"journal_rejected","freshness_ms":1000,"destination_generation":"g","period_id":"p"}"#
        if case .accept = decode(failedWithCause, direction: "host_to_extension") {
        } else {
            #expect(Bool(false), "failed delivery with failure should decode")
        }

        let decoy = #"{"extra":{"records":[{"unvalidated":true}]},"type":"batch","destination_generation":"g","inst":"i","batch_id":"0123456789abcdef0123456789abcdef","queued_at_ms":0,"records":[{"t":"segment_start","ts":1000.0,"ctx":"c","blocks":[{"id":"b","text":"real"}]}]}"#
        if case .accept(.batch(let batch)) = decode(decoy) {
            let slice = String(decoding: batch.records[0].rawSlice, as: UTF8.self)
            #expect(slice.contains("\"ts\":1000.0"))
            #expect(slice.contains("real"))
            #expect(!slice.contains("unvalidated"))
        } else {
            #expect(Bool(false), "root records should be the persisted slice")
        }

        func nestedJSON(depth: Int) -> String {
            String(repeating: "{\"a\":", count: depth) + "1" + String(repeating: "}", count: depth)
        }
        if case .refuse(let shallow) = decode(nestedJSON(depth: 127)) {
            #expect(shallow.code != "bad_json")
        }
        if case .refuse(let deep) = decode(nestedJSON(depth: 128)) {
            #expect(deep.code == "bad_json")
        } else {
            #expect(Bool(false), "depth 128 should be bad_json")
        }
    }

    private func buildRecipe(id: String, projection: BrowserContractProjection) -> Data {
        let extMax = projection.caps.extensionToHost
        let controlMax = projection.caps.control

        if id == "extension_to_host_batch_max" || id == "extension_to_host_batch_oversize" {
            let targetLen = (id == "extension_to_host_batch_max") ? extMax : extMax + 1
            var baseObj: [String: Any] = [
                "type": "batch",
                "destination_generation": "g",
                "inst": "i",
                "batch_id": "0123456789abcdef0123456789abcdef",
                "queued_at_ms": 0,
                "records": [
                    [
                        "t": "segment_start",
                        "ts": 0,
                        "ctx": "c",
                        "blocks": [["id": "b", "text": "x"]]
                    ]
                ],
                "pad": ""
            ]
            let emptyBytes = encodeCanonical(baseObj, projection: projection)
            let padLen = targetLen - emptyBytes.count
            baseObj["pad"] = String(repeating: "a", count: padLen)
            return encodeCanonical(baseObj, projection: projection)
        } else if id == "control_payload_max" || id == "control_payload_oversize" {
            let targetLen = (id == "control_payload_max") ? controlMax : controlMax + 1
            var baseObj: [String: Any] = [
                "type": "hello",
                "protocol": 1,
                "version": "1.0.0",
                "brand": "chrome",
                "inst": "inst1",
                "pad": ""
            ]
            let emptyBytes = encodeCanonical(baseObj, projection: projection)
            let padLen = targetLen - emptyBytes.count
            baseObj["pad"] = String(repeating: "a", count: padLen)
            return encodeCanonical(baseObj, projection: projection)
        } else if id == "batch_delta_cap_3000" {
            var deltas: [[String: Any]] = []
            for i in 0..<1500 {
                deltas.append(["t": "delta", "ts": 0, "ctx": "c", "op": "add", "block": ["id": "a\(i)", "text": "t"]])
                deltas.append(["t": "delta", "ts": 0, "ctx": "c", "op": "remove", "block": ["id": "r\(i)"]])
            }
            let baseObj: [String: Any] = [
                "type": "batch",
                "destination_generation": "g",
                "inst": "i",
                "batch_id": "0123456789abcdef0123456789abcdef",
                "queued_at_ms": 0,
                "records": deltas
            ]
            return encodeCanonical(baseObj, projection: projection)
        } else if id == "batch_delta_oversize_3001" {
            var deltas: [[String: Any]] = []
            for i in 0..<1500 {
                deltas.append(["t": "delta", "ts": 0, "ctx": "c", "op": "add", "block": ["id": "a\(i)", "text": "t"]])
                deltas.append(["t": "delta", "ts": 0, "ctx": "c", "op": "remove", "block": ["id": "r\(i)"]])
            }
            deltas.append(["t": "delta", "ts": 0, "ctx": "c", "op": "add", "block": ["id": "extra", "text": "t"]])
            let baseObj: [String: Any] = [
                "type": "batch",
                "destination_generation": "g",
                "inst": "i",
                "batch_id": "0123456789abcdef0123456789abcdef",
                "queued_at_ms": 0,
                "records": deltas
            ]
            return encodeCanonical(baseObj, projection: projection)
        }
        return Data()
    }

    private func encodeCanonical(_ obj: [String: Any], projection: BrowserContractProjection) -> Data {
        return BrowserPayloadDecoder.canonicalEncode(obj, projection: projection)
    }
}

#endif
