import Foundation
import Testing
import SolstoneCore
@testable import sol_mac

@Suite("SolMacConfig")
struct SolMacConfigTests {
    @Test func setAndGetServerURL() {
        let domain = makeDomain()
        defer { cleanup(domain: domain) }

        #expect(cfWrite(key: "serverURL", value: "https://example.com", domain: domain))
        #expect(cfRead(key: "serverURL", domain: domain) as? String == "https://example.com")
    }

    @Test func setBoolAcceptsTrueFalseYesNo10() throws {
        let truthy = ["true", "yes", "1"]
        for value in truthy {
            let parsed = try parseScalar(key: "syncPaused", value: value) as? NSNumber
            #expect(parsed?.boolValue == true)
        }

        let falsey = ["false", "no", "0"]
        for value in falsey {
            let parsed = try parseScalar(key: "syncPaused", value: value) as? NSNumber
            #expect(parsed?.boolValue == false)
        }
    }

    @Test func setRejectsBadBool() {
        #expect(throws: ConfigParseError.self) {
            try parseScalar(key: "syncPaused", value: "maybe")
        }
    }

    @Test func setRejectsComplexKey() {
        #expect(!scalarWritableKeys.contains("microphonePriority"))
    }

    @Test func setRejectsUnknownKey() {
        #expect(!AppConfig.knownKeys.contains("foo"))
    }

    @Test func unsetClearsKey() {
        let domain = makeDomain()
        defer { cleanup(domain: domain) }

        #expect(cfWrite(key: "serverKey", value: "abc123", domain: domain))
        #expect(cfRead(key: "serverKey", domain: domain) as? String == "abc123")

        #expect(cfWrite(key: "serverKey", value: nil, domain: domain))
        #expect(cfRead(key: "serverKey", domain: domain) == nil)
    }
}

private func makeDomain() -> CFString {
    "app.solstone.observer.tests.\(UUID().uuidString)" as CFString
}

private func cleanup(domain: CFString) {
    for key in AppConfig.knownKeys {
        CFPreferencesSetAppValue(key as CFString, nil, domain)
    }
    _ = CFPreferencesAppSynchronize(domain)
}
