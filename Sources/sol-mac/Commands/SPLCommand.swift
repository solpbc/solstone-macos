// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import ArgumentParser
import Foundation
import SolstoneCore
import SPLTunnel

struct SPL: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spl",
        abstract: "pair and test sol private link.",
        subcommands: [Pair.self, Unpair.self, Status.self, DialTest.self]
    )
}

extension SPL {
    struct Pair: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pair",
            abstract: "pair this device with a sol private link home.",
            discussion: """
            note: this command may trigger a macOS keychain unlock prompt because the
            sol-mac CLI runs unbundled. authorize once to allow writing the pairing bundle.
            """
        )

        @Option(name: .customLong("pair-url"))
        var pairUrl: String

        @Option(name: .customLong("device-label"))
        var deviceLabel: String = ProcessInfo.processInfo.hostName

        @Option(name: .customLong("relay-endpoint"))
        var relayEndpoint: String = "https://spl-relay-staging.jer-3f2.workers.dev"

        func run() async throws {
            guard let relayURL = URL(string: relayEndpoint) else {
                writeStructuredStderr(code: "invalid_relay_endpoint", message: "relay endpoint is malformed")
                throw ExitCode(SolMacExit.localValidation.rawValue)
            }

            let parsedPairURL: PairURL
            do {
                guard let url = URL(string: pairUrl) else {
                    writeStructuredStderr(code: "invalid_pair_url", message: "pair url is malformed")
                    throw ExitCode(SolMacExit.localValidation.rawValue)
                }
                parsedPairURL = try PairURL.parse(url)
            } catch let error as PairURLError {
                writeStructuredStderr(code: "invalid_pair_url", message: pairURLMessage(error))
                throw ExitCode(SolMacExit.localValidation.rawValue)
            } catch let exit as ExitCode {
                throw exit
            }

            do {
                let stored = try await PairClient().pair(
                    pairURL: parsedPairURL,
                    deviceLabel: deviceLabel,
                    relayEndpoint: relayURL
                )
                try SPLKeychain.save(stored)
                let fingerprint = stripSHA256Prefix(stored.fingerprint)
                print("paired with \(stored.homeLabel) (instance \(stored.instanceID.prefix(8)), fingerprint \(fingerprint.prefix(12)))")
            } catch let error as PairError {
                writeStructuredStderr(code: pairErrorCode(error), message: error.localizedDescription)
                throw ExitCode(SolMacExit.localValidation.rawValue)
            } catch let error as SPLKeychainError {
                writeStructuredStderr(code: "keychain_failed", message: keychainMessage(error))
                throw ExitCode(SolMacExit.localValidation.rawValue)
            } catch {
                writeStructuredStderr(code: "pair_failed", message: error.localizedDescription)
                throw ExitCode(SolMacExit.localValidation.rawValue)
            }
        }
    }

    struct Unpair: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "unpair",
            abstract: "remove the local sol private link pairing."
        )

        func run() async throws {
            do {
                try SPLKeychain.delete()
                print("unpaired locally — also unpair this device from convey to revoke server-side")
            } catch let error as SPLKeychainError {
                writeStructuredStderr(code: "keychain_failed", message: keychainMessage(error))
                throw ExitCode(SolMacExit.localValidation.rawValue)
            }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "show the local sol private link pairing."
        )

        func run() async throws {
            do {
                guard let stored = try SPLKeychain.load() else {
                    print("not paired")
                    return
                }

                let formatter = ISO8601DateFormatter()
                let fingerprint = stripSHA256Prefix(stored.fingerprint)
                print("home_label: \(stored.homeLabel)")
                print("instance_id: \(stored.instanceID)")
                print("fingerprint: \(fingerprint.prefix(16))")
                print("paired_at: \(formatter.string(from: stored.pairedAt))")
                print("relay_endpoint: \(stored.relayEndpoint)")
                let entryWord = stored.localEndpoints.count == 1 ? "entry" : "entries"
                print("local_endpoints: \(stored.localEndpoints.count) \(entryWord)")
                for endpoint in stored.localEndpoints {
                    print("  - \(endpoint.host):\(endpoint.port) (\(endpoint.scope))")
                }
            } catch let error as SPLKeychainError {
                writeStructuredStderr(code: "keychain_failed", message: keychainMessage(error))
                throw ExitCode(SolMacExit.localValidation.rawValue)
            }
        }
    }

    struct DialTest: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "dial-test",
            abstract: "open a sol private link tunnel and request home status."
        )

        func run() async throws {
            let stored: StoredPairing
            do {
                guard let loaded = try SPLKeychain.load() else {
                    writeStructuredStderr(code: "not_paired", message: "not paired")
                    throw ExitCode(SolMacExit.localValidation.rawValue)
                }
                stored = loaded
            } catch let error as SPLKeychainError {
                writeStructuredStderr(code: "keychain_failed", message: keychainMessage(error))
                throw ExitCode(SolMacExit.localValidation.rawValue)
            }

            let tunnel = TunnelSession(pairing: stored)
            do {
                let via = try await tunnel.connect(endpoints: TransportEndpoint.candidates(for: stored))
                let stream = try await tunnel.openStream()
                let request = "GET /app/link/api/status HTTP/1.1\r\nHost: \(stored.homeLabel)\r\nConnection: close\r\n\r\n"
                try await stream.write(Data(request.utf8))
                try await stream.close()
                let response = try await readResponse(from: await stream.inbound)

                print("transport: \(transportName(via))")
                print("status: \(response.statusLine)")
                print("body: \(response.body)")
                await tunnel.disconnect()
            } catch let exit as ExitCode {
                await tunnel.disconnect()
                throw exit
            } catch {
                await tunnel.disconnect()
                writeStructuredStderr(code: "dial_failed", message: error.localizedDescription)
                throw ExitCode(SolMacExit.localValidation.rawValue)
            }
        }
    }
}

private func pairURLMessage(_ error: PairURLError) -> String {
    switch error {
    case .wrongScheme(nil):
        return "pair url must use https"
    case .wrongScheme(let scheme?):
        return "pair url scheme must be https, got \(scheme)"
    case .wrongHost(nil):
        return "pair url must use link.solpbc.org"
    case .wrongHost(let host?):
        return "pair url host must be link.solpbc.org, got \(host)"
    case .wrongPath(let path):
        return "pair url path must be /p, got \(path)"
    case .missingFragment:
        return "pair url is missing its fragment"
    case .invalidBase32(.outOfAlphabet(let character)):
        return "pair url contains an invalid character: \(character)"
    case .invalidBase32(.nonCanonicalPadBits):
        return "pair url contains invalid encoded data"
    case .invalidVersion(let version):
        return "pair url version is unsupported: \(hexByte(version))"
    case .unsupportedAddrType(let addressType):
        return "pair url address type is unsupported: \(hexByte(addressType))"
    case .invalidLength(let count):
        return "pair url data length is invalid: \(count) bytes"
    case .malformedOuterURL:
        return "pair url is malformed"
    }
}

private func hexByte(_ value: UInt8) -> String {
    String(format: "0x%02x", value)
}

private func pairErrorCode(_ error: PairError) -> String {
    switch error {
    case .csrBuildFailed:
        return "csr_build_failed"
    case .lanRequestFailed:
        return "lan_request_failed"
    case .lanCAFingerprintMismatch:
        return "lan_ca_fingerprint_mismatch"
    case .lanResponseInvalid:
        return "lan_response_invalid"
    case .nonceExpired:
        return "nonce_expired"
    case .relayRequestFailed:
        return "relay_request_failed"
    case .relayResponseInvalid:
        return "relay_response_invalid"
    case .attestationRejected:
        return "attestation_rejected"
    }
}

private func keychainMessage(_ error: SPLKeychainError) -> String {
    switch error {
    case .encodingFailed:
        return "could not encode the pairing bundle"
    case .decodingFailed:
        return "could not decode the pairing bundle"
    case .saveFailed(let status):
        return "keychain save failed: \(status)"
    case .loadFailed(let status):
        return "keychain load failed: \(status)"
    case .deleteFailed(let status):
        return "keychain delete failed: \(status)"
    }
}

private func stripSHA256Prefix(_ fingerprint: String) -> String {
    if fingerprint.lowercased().hasPrefix("sha256:") {
        return String(fingerprint.dropFirst("sha256:".count))
    }
    return fingerprint
}

private func waitForConnected(_ tunnel: TunnelSession) async throws -> ConnectedVia {
    try await withThrowingTaskGroup(of: ConnectedVia.self) { group in
        group.addTask {
            for await state in tunnel.stateUpdates {
                switch state {
                case .connected(let via):
                    return via
                case .failed(let error):
                    throw error
                case .disconnected, .connecting, .tlsHandshaking:
                    break
                }
            }
            throw SessionError.transportFailed("state stream closed")
        }

        group.addTask {
            try await Task.sleep(for: .seconds(30))
            throw SessionError.transportFailed("timed out waiting for connection")
        }

        let via = try await group.next()!
        group.cancelAll()
        return via
    }
}

private func readResponse(from inbound: AsyncThrowingStream<Data, Error>) async throws -> (statusLine: String, body: String) {
    var data = Data()
    for try await chunk in inbound {
        data.append(chunk)
    }
    guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
          let headerText = String(data: data[..<separator.lowerBound], encoding: .utf8),
          let statusLine = headerText.components(separatedBy: "\r\n").first else {
        throw SessionError.transportFailed("invalid http response")
    }
    let body = String(data: data[separator.upperBound...], encoding: .utf8) ?? ""
    return (statusLine, body)
}

private func transportName(_ via: ConnectedVia) -> String {
    switch via {
    case .lanDirect:
        return "lan"
    case .relay:
        return "relay"
    }
}
