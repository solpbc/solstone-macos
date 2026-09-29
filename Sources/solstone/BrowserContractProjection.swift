// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Foundation

public final class BrowserContractProjection: Sendable {
    public struct Caps: Sendable {
        public let extensionToHost: Int
        public let hostToExtension: Int
        public let control: Int
        public let deltaRecords: Int
        public let batchIdHex: Int
        public let jsonMaxDepth: Int
    }

    public struct Policy: Sendable {
        public let file: Int
        public let outboxBytes: Int
        public let outboxAgeMs: UInt64
        public let spoolBytes: Int
        public let spoolAgeMs: UInt64
        public let futureSkewMs: UInt64
        public let acceptedRetentionMs: UInt64
        public let handshakeMs: UInt64
        public let stateRenewalMs: UInt64
        public let freshnessMaxMs: UInt64
        public let partialFrameMs: UInt64
        public let timestampMax: UInt64
    }

    public struct HostIds: Sendable {
        public let host: String
        public let chromeId: String
        public let edgeId: String
        public let firefoxId: String
    }

    public struct StringBounds: Sendable {
        public let version: Int
        public let generation: Int
        public let periodId: Int
        public let failureCode: Int
        public let instStringMax: Int
        public let idStringMax: Int
        public let titleStringMax: Int
        public let urlStringMax: Int
        public let siteStringMax: Int
        public let adapterStringMax: Int
        public let ctxStringMax: Int
        public let typeStringMax: Int
        public let linkHostStringMax: Int
        public let levelStringMax: Int
        public let labelStringMax: Int
        public let textMax: Int
        public let blockDepthMax: Int
        public let blocksMax: Int
    }

    public let rootURL: URL
    public let bundleVersion: String
    public let wireProtocol: Int
    public let caps: Caps
    public let policy: Policy
    public let prodHosts: HostIds
    public let devHosts: HostIds
    public let stringBounds: StringBounds
    public let receiptClasses: [String: [String]]
    public let canonicalKeyOrder: [String: [String]]
    public let constantsRs: [String: String]
    public let authorityJsonData: Data
    public let envelopeSchemaData: Data
    public let browserSchemaData: Data
    public let manifestJsonData: Data

    public static func vendorRootURL(bundleURL: URL) -> URL? {
        let root = bundleURL.appendingPathComponent("Contents/Resources/vendor", isDirectory: true)
        let relativePaths = [
            "contracts/native-browser/authority.json",
            "crates/native-browser-frame/src/constants.rs",
            "contracts/native-browser/envelope.schema.json",
            "contracts/native-browser/browser.schema.json",
            "contracts/native-browser/manifest.json"
        ]
        guard relativePaths.allSatisfy({ FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }) else {
            return nil
        }
        return root
    }

    public init(rootURL: URL) throws {
        self.rootURL = rootURL

        let authorityURL = rootURL.appendingPathComponent("contracts/native-browser/authority.json")
        let authorityData = try Data(contentsOf: authorityURL)
        self.authorityJsonData = authorityData

        guard let authObj = try JSONSerialization.jsonObject(with: authorityData) as? [String: Any],
              let bundleVersion = authObj["bundle_version"] as? String,
              let wireProtocol = authObj["wire_protocol"] as? Int,
              let capsDict = authObj["caps"] as? [String: Any],
              let extensionToHost = capsDict["extension_to_host"] as? Int,
              let hostToExtension = capsDict["host_to_extension"] as? Int,
              let control = capsDict["control"] as? Int,
              let deltaRecords = capsDict["delta_records"] as? Int,
              let batchIdHex = capsDict["batch_id_hex"] as? Int,
              let jsonMaxDepth = capsDict["json_max_depth"] as? Int,
              let polDict = authObj["policy"] as? [String: Any],
              let filePolicy = polDict["file"] as? Int,
              let outboxBytes = polDict["outbox_bytes"] as? Int,
              let outboxAgeMs = (polDict["outbox_age_ms"] as? NSNumber)?.uint64Value,
              let spoolBytes = polDict["spool_bytes"] as? Int,
              let spoolAgeMs = (polDict["spool_age_ms"] as? NSNumber)?.uint64Value,
              let futureSkewMs = (polDict["future_skew_ms"] as? NSNumber)?.uint64Value,
              let acceptedRetentionMs = (polDict["accepted_retention_ms"] as? NSNumber)?.uint64Value,
              let handshakeMs = (polDict["handshake_ms"] as? NSNumber)?.uint64Value,
              let stateRenewalMs = (polDict["state_renewal_ms"] as? NSNumber)?.uint64Value,
              let freshnessMaxMs = (polDict["freshness_max_ms"] as? NSNumber)?.uint64Value,
              let partialFrameMs = (polDict["partial_frame_ms"] as? NSNumber)?.uint64Value,
              let timestampMax = (polDict["timestamp_max"] as? NSNumber)?.uint64Value,
              let hostsDict = authObj["hosts_and_ids"] as? [String: Any],
              let prodDict = hostsDict["production"] as? [String: Any],
              let prodHost = prodDict["host"] as? String,
              let prodChromeId = prodDict["chrome_id"] as? String,
              let prodEdgeId = prodDict["edge_id"] as? String,
              let prodFirefoxId = prodDict["firefox_id"] as? String,
              let devDict = hostsDict["dev"] as? [String: Any],
              let devHost = devDict["host"] as? String,
              let devChromeId = devDict["chrome_id"] as? String,
              let devEdgeId = devDict["edge_id"] as? String,
              let devFirefoxId = devDict["firefox_id"] as? String,
              let sbDict = authObj["string_bounds"] as? [String: Any],
              let versionBound = sbDict["version"] as? Int,
              let genBound = sbDict["generation"] as? Int,
              let periodIdBound = sbDict["period_id"] as? Int,
              let failureCodeBound = sbDict["failure_code"] as? Int,
              let receiptClasses = authObj["receipt_classes"] as? [String: [String]],
              let canonicalKeyOrder = authObj["canonical_key_order"] as? [String: [String]] else {
            throw NSError(domain: "BrowserContractProjection", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid or incomplete authority.json"])
        }

        self.bundleVersion = bundleVersion
        self.wireProtocol = wireProtocol
        self.caps = Caps(
            extensionToHost: extensionToHost,
            hostToExtension: hostToExtension,
            control: control,
            deltaRecords: deltaRecords,
            batchIdHex: batchIdHex,
            jsonMaxDepth: jsonMaxDepth
        )
        self.policy = Policy(
            file: filePolicy,
            outboxBytes: outboxBytes,
            outboxAgeMs: outboxAgeMs,
            spoolBytes: spoolBytes,
            spoolAgeMs: spoolAgeMs,
            futureSkewMs: futureSkewMs,
            acceptedRetentionMs: acceptedRetentionMs,
            handshakeMs: handshakeMs,
            stateRenewalMs: stateRenewalMs,
            freshnessMaxMs: freshnessMaxMs,
            partialFrameMs: partialFrameMs,
            timestampMax: timestampMax
        )
        self.prodHosts = HostIds(
            host: prodHost,
            chromeId: prodChromeId,
            edgeId: prodEdgeId,
            firefoxId: prodFirefoxId
        )
        self.devHosts = HostIds(
            host: devHost,
            chromeId: devChromeId,
            edgeId: devEdgeId,
            firefoxId: devFirefoxId
        )
        self.receiptClasses = receiptClasses
        self.canonicalKeyOrder = canonicalKeyOrder

        // Read constants.rs
        let constantsRsURL = rootURL.appendingPathComponent("crates/native-browser-frame/src/constants.rs")
        let constantsRsContent = try String(contentsOf: constantsRsURL, encoding: .utf8)
        var parsedConstants: [String: String] = [:]
        for line in constantsRsContent.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("pub const ") {
                let rest = trimmed.dropFirst("pub const ".count)
                if let colonIdx = rest.firstIndex(of: ":") {
                    let name = String(rest[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                    let afterColon = rest[rest.index(after: colonIdx)...]
                    if let eqIdx = afterColon.firstIndex(of: "=") {
                        var val = String(afterColon[afterColon.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
                        if val.hasSuffix(";") { val = String(val.dropLast()).trimmingCharacters(in: .whitespaces) }
                        parsedConstants[name] = val
                    }
                }
            }
        }
        self.constantsRs = parsedConstants

        guard let instStringMax = parsedConstants["INST_STRING_MAX"].flatMap(Int.init),
              let idStringMax = parsedConstants["ID_STRING_MAX"].flatMap(Int.init),
              let titleStringMax = parsedConstants["TITLE_STRING_MAX"].flatMap(Int.init),
              let urlStringMax = parsedConstants["URL_STRING_MAX"].flatMap(Int.init),
              let siteStringMax = parsedConstants["SITE_STRING_MAX"].flatMap(Int.init),
              let adapterStringMax = parsedConstants["ADAPTER_STRING_MAX"].flatMap(Int.init),
              let ctxStringMax = parsedConstants["CTX_STRING_MAX"].flatMap(Int.init),
              let typeStringMax = parsedConstants["TYPE_STRING_MAX"].flatMap(Int.init),
              let linkHostStringMax = parsedConstants["LINK_HOST_STRING_MAX"].flatMap(Int.init),
              let levelStringMax = parsedConstants["LEVEL_STRING_MAX"].flatMap(Int.init),
              let labelStringMax = parsedConstants["LABEL_STRING_MAX"].flatMap(Int.init),
              let textMax = parsedConstants["TEXT_MAX"].flatMap(Int.init),
              let blockDepthMax = parsedConstants["BLOCK_DEPTH_MAX"].flatMap(Int.init),
              let blocksMax = parsedConstants["BLOCKS_MAX"].flatMap(Int.init) else {
            throw NSError(domain: "BrowserContractProjection", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid or incomplete constants.rs"])
        }

        self.stringBounds = StringBounds(
            version: versionBound,
            generation: genBound,
            periodId: periodIdBound,
            failureCode: failureCodeBound,
            instStringMax: instStringMax,
            idStringMax: idStringMax,
            titleStringMax: titleStringMax,
            urlStringMax: urlStringMax,
            siteStringMax: siteStringMax,
            adapterStringMax: adapterStringMax,
            ctxStringMax: ctxStringMax,
            typeStringMax: typeStringMax,
            linkHostStringMax: linkHostStringMax,
            levelStringMax: levelStringMax,
            labelStringMax: labelStringMax,
            textMax: textMax,
            blockDepthMax: blockDepthMax,
            blocksMax: blocksMax
        )

        self.envelopeSchemaData = try Data(contentsOf: rootURL.appendingPathComponent("contracts/native-browser/envelope.schema.json"))
        self.browserSchemaData = try Data(contentsOf: rootURL.appendingPathComponent("contracts/native-browser/browser.schema.json"))
        self.manifestJsonData = try Data(contentsOf: rootURL.appendingPathComponent("contracts/native-browser/manifest.json"))
    }
}

#endif
