// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel

enum SPLRuntime {
    static var clientInfo: SPLClientInfo {
        SPLClientInfo(userAgent: "solstone-macos/\(AppVersion.short)")
    }
}

enum SPLPairingKeychain {
    static let markerKey = "SolstoneSPLKeychainPlane"
    static let loginKeychainMarkerValue = "login-keychain"

    static func store(markerValue: String? = Bundle.main.object(forInfoDictionaryKey: markerKey) as? String) -> SPLKeychainStore {
        SPLKeychainStore(policy: policy(markerValue: markerValue))
    }

    static func policy(markerValue: String?) -> KeychainPolicy {
        if markerValue == loginKeychainMarkerValue {
            return loginKeychainPolicy
        }
        return productionPolicy
    }

    static let productionPolicy = KeychainPolicy(
        service: service,
        account: account,
        accessGroup: accessGroup,
        useDataProtectionKeychain: true,
        accessibility: .afterFirstUnlockThisDeviceOnly
    )

    static let loginKeychainPolicy = KeychainPolicy(
        service: service,
        account: account,
        accessGroup: nil,
        useDataProtectionKeychain: false,
        accessibility: .afterFirstUnlockThisDeviceOnly
    )

    static let service = "app.solstone.observer.spl"
    static let account = "spl-pairing-bundle"
    // Team-prefixed Data Protection keychain access group. Access is gated by Team ID,
    // not the binary code signature, so pairing survives every Sparkle app update
    // (changed cdhash) with zero prompts.
    //
    // MUST stay byte-for-byte identical to `keychain-access-groups` in
    // Sources/solstone/entitlements-app.plist AND the embedded
    // Contents/embedded.provisionprofile. SPLPairingKeychainTests.policyLiteralsMatchEntitlementsAppPlist
    // guards this Swift↔entitlement
    // drift: if the three copies disagree, the signed app gets a silent
    // errSecMissingEntitlement (-34018) at runtime. Verified working in this exact
    // team-prefixed form on hardware 2026-07-02 — do not reformat or drop the team prefix.
    static let accessGroup = "7QCG8V4M6H.app.solstone.observer.spl"
}
