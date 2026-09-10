// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum SupportReportURL {
    static let help = URL(string: "https://support.solstone.app")!

    static func make(
        version: String,
        build: String,
        osVersion: String,
        state: String,
        recent: String?
    ) -> URL {
        var fields = [
            ("report", "v1"),
            ("app", "solstone for mac"),
        ]
        if !version.isEmpty {
            fields.append(("version", String(version.prefix(120))))
        }
        if !build.isEmpty {
            fields.append(("build", String(build.prefix(120))))
        }
        fields.append(("os", "macos"))
        if !osVersion.isEmpty {
            fields.append(("os_version", String(osVersion.prefix(120))))
        }
        if !state.isEmpty {
            fields.append(("state", String(state.prefix(500))))
        }
        if let recent, !recent.isEmpty {
            fields.append(("recent", String(recent.prefix(4000))))
        }
        let fragment = fields.map { key, value in
            "\(formEncode(key))=\(formEncode(value))"
        }.joined(separator: "&")
        return URL(string: "https://support.solstone.app/#\(fragment)")!
    }

    private static func formEncode(_ value: String) -> String {
        value.utf8.map { byte in
            if byte == 0x20 { return "+" }
            if byte.isASCIIAlphaNumeric || [0x2A, 0x2D, 0x2E, 0x5F].contains(byte) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }
}

private extension UInt8 {
    nonisolated var isASCIIAlphaNumeric: Bool {
        (0x30...0x39).contains(self) || (0x41...0x5A).contains(self) || (0x61...0x7A).contains(self)
    }
}
