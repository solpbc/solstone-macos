// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore

internal enum JournalWebHostContract {
    private enum RejectionReason: String {
        case missing
        case malformed
        case unsupported
    }

    static func packagedBytes(bundle: Bundle = .module) -> Data? {
        guard let url = bundle.url(
            forResource: "host-contract",
            withExtension: "json",
            subdirectory: "Resources"
        ) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    static func userAgentProduct(
        from data: Data?,
        logSink: any ClassifiedLogSinking = LoggerClassifiedLogSink.journal
    ) -> String? {
        guard let data else {
            return reject(.missing, to: logSink)
        }

        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            return reject(.malformed, to: logSink)
        }

        guard let object = json as? [String: Any] else {
            return reject(.malformed, to: logSink)
        }
        guard let version = object["version"], isVersionOne(version),
              let product = object["user_agent_product"] as? String,
              isSingleUserAgentToken(product)
        else {
            return reject(.unsupported, to: logSink)
        }

        return product
    }

    private static func isVersionOne(_ value: Any) -> Bool {
        // JSON booleans and floating-point numbers bridge through NSNumber too.
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number as CFNumber)
        else {
            return false
        }

        return number.int64Value == 1
    }

    private static func isSingleUserAgentToken(_ product: String) -> Bool {
        !product.isEmpty && product.unicodeScalars.allSatisfy {
            $0.value > 0x20 && $0.value != 0x7F
        }
    }

    private static func reject(
        _ reason: RejectionReason,
        to logSink: any ClassifiedLogSinking
    ) -> String? {
        logSink.emit(ClassifiedLogEmission(
            level: .error,
            classification: "journal-web-host-contract",
            publicFields: ["reason": reason.rawValue]
        ))
        return nil
    }
}
