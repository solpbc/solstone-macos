// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation
import Network
import Security
@testable import SPLTunnel

actor MockHome {
    private let caKey = P256.Signing.PrivateKey()
    private let homeSigningKey = P256.Signing.PrivateKey()
    private let instanceID = "mockhome-\(UUID().uuidString.lowercased())"
    private let homeLabel = "MockHome Test"
    private let caCertPEM: String
    private let pairServerCertPEM: String
    private let pairServerKeyPEM: String
    private let muxServerCertPEM: String
    private let muxServerKeyPEM: String
    private let pairServerFingerprint: String
    private let authorizedClients = MockAuthorizedClients()
    private var outstandingNonces: Set<String> = []
    private var pairListener: NWListener?
    private var muxListener: NWListener?
    private var muxPort: UInt16?
    private var pairConnections: [NWConnection] = []
    private var muxConnections: [NWConnection] = []

    init() throws {
        let pairKey = P256.Signing.PrivateKey()
        let muxKey = P256.Signing.PrivateKey()
        let caDER = try CertBuilder.certificate(
            subject: "MockHome CA",
            issuer: "MockHome CA",
            subjectPublicKey: caKey.publicKey,
            issuerPrivateKey: caKey,
            isCA: true,
            extendedKeyUsage: []
        )
        caCertPEM = CryptoCSR.pemEncode(caDER, label: "CERTIFICATE")
        let pairDER = try CertBuilder.certificate(
            subject: "127.0.0.1",
            issuer: "MockHome CA",
            subjectPublicKey: pairKey.publicKey,
            issuerPrivateKey: caKey,
            isCA: false,
            extendedKeyUsage: [CertBuilder.oidServerAuth],
            subjectAlternativeNames: true
        )
        pairServerCertPEM = CryptoCSR.pemEncode(pairDER, label: "CERTIFICATE")
        pairServerKeyPEM = CryptoCSR.pemEncode(CryptoCSR.exportPKCS8(pairKey), label: "PRIVATE KEY")
        let muxDER = try CertBuilder.certificate(
            subject: "127.0.0.1",
            issuer: "MockHome CA",
            subjectPublicKey: muxKey.publicKey,
            issuerPrivateKey: caKey,
            isCA: false,
            extendedKeyUsage: [CertBuilder.oidServerAuth],
            subjectAlternativeNames: true
        )
        muxServerCertPEM = CryptoCSR.pemEncode(muxDER, label: "CERTIFICATE")
        muxServerKeyPEM = CryptoCSR.pemEncode(CryptoCSR.exportPKCS8(muxKey), label: "PRIVATE KEY")
        pairServerFingerprint = try TestCA.fingerprint(certificatePEM: pairServerCertPEM)
    }

    func startPairServer() async throws -> URL {
        if let port = pairListener?.port?.rawValue {
            return URL(string: "https://127.0.0.1:\(port)")!
        }

        let identity = try TestCA.secIdentity(certificatePEM: pairServerCertPEM, privateKeyPEM: pairServerKeyPEM)
        let options = NWProtocolTLS.Options()
        let secOptions = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(secOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(secOptions, .TLSv13)
        sec_protocol_options_set_local_identity(secOptions, identity)
        let parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let waiter = MockListenerReadyWaiter()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port?.rawValue {
                    waiter.complete(.success(port))
                } else {
                    waiter.complete(.failure(MockHomeError.listenerMissingPort))
                }
            case .failed(let error):
                waiter.complete(.failure(error))
            case .cancelled, .setup, .waiting:
                break
            @unknown default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.acceptPair(connection)
            }
        }
        pairListener = listener
        listener.start(queue: .global(qos: .utility))
        let port = try await waiter.wait()
        return URL(string: "https://127.0.0.1:\(port)")!
    }

    func mintPairNonce() throws -> (pairURL: PairURL, pairURLString: String?) {
        guard let port = pairListener?.port?.rawValue else {
            throw MockHomeError.pairServerNotStarted
        }
        let nonceBytes = Array(Self.randomBytes(count: 8))
        let nonceHex = CertChain.hex(nonceBytes)
        outstandingNonces.insert(nonceHex)
        let fingerprintBytes = try Self.hexBytes(pairServerFingerprint)
        guard fingerprintBytes.count >= 16 else {
            throw MockHomeError.invalidPairServerFingerprint
        }
        var blob: [UInt8] = [0x02, 0x01, 0x7F, 0x00, 0x00, 0x01]
        blob.append(UInt8((port >> 8) & 0xff))
        blob.append(UInt8(port & 0xff))
        blob.append(contentsOf: nonceBytes)
        blob.append(contentsOf: fingerprintBytes.prefix(16))
        let pairURLString = "https://link.solpbc.org/p#\(Self.encode(blob))"
        let pairURL = try PairURL.parse(URL(string: pairURLString)!)
        return (pairURL, pairURLString)
    }

    func startTLSMuxListener() async throws -> (host: String, port: UInt16) {
        if let port = muxListener?.port?.rawValue {
            return ("127.0.0.1", port)
        }

        let anchors = try CertChain.certificates(fromPEM: caCertPEM)
        let identity = try TestCA.secIdentity(certificatePEM: muxServerCertPEM, privateKeyPEM: muxServerKeyPEM)
        let options = NWProtocolTLS.Options()
        let secOptions = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(secOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(secOptions, .TLSv13)
        sec_protocol_options_set_local_identity(secOptions, identity)
        sec_protocol_options_set_peer_authentication_required(secOptions, true)
        let authorizedClients = self.authorizedClients
        sec_protocol_options_set_verify_block(secOptions, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            SecTrustSetPolicies(secTrust, SecPolicyCreateBasicX509())
            SecTrustSetAnchorCertificates(secTrust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(secTrust, true)
            var error: CFError?
            guard SecTrustEvaluateWithError(secTrust, &error),
                  let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                  let leaf = chain.first else {
                complete(false)
                return
            }
            complete(authorizedClients.contains(CertChain.sha256Fingerprint(of: leaf)))
        }, .global(qos: .utility))

        let parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: muxPort.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any)
        let listener = try NWListener(using: parameters)
        let waiter = MockListenerReadyWaiter()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port?.rawValue {
                    waiter.complete(.success(port))
                } else {
                    waiter.complete(.failure(MockHomeError.listenerMissingPort))
                }
            case .failed(let error):
                waiter.complete(.failure(error))
            case .cancelled, .setup, .waiting:
                break
            @unknown default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.acceptMux(connection)
            }
        }
        muxListener = listener
        listener.start(queue: .global(qos: .utility))
        let port = try await waiter.wait()
        muxPort = port
        return ("127.0.0.1", port)
    }

    func stopTLSMuxListener() {
        for connection in muxConnections {
            connection.cancel()
        }
        muxConnections.removeAll()
        muxListener?.cancel()
        muxListener = nil
    }

    func stop() {
        for connection in pairConnections + muxConnections {
            connection.cancel()
        }
        pairConnections.removeAll()
        muxConnections.removeAll()
        pairListener?.cancel()
        pairListener = nil
        muxListener?.cancel()
        muxListener = nil
    }

    private func acceptPair(_ connection: NWConnection) {
        pairConnections.append(connection)
        connection.start(queue: .global(qos: .utility))
        Task {
            await handlePair(connection)
        }
    }

    private func acceptMux(_ connection: NWConnection) {
        muxConnections.append(connection)
        connection.start(queue: .global(qos: .utility))
        Task {
            await handleMux(connection)
        }
    }

    private func handlePair(_ connection: NWConnection) async {
        do {
            let request = try await MockHTTPConnection.readRequest(from: connection)
            guard request.method == "POST", request.path == "/app/link/pair" else {
                try await MockHTTPConnection.send(status: 404, body: #"{"error":"not_found"}"#, to: connection)
                connection.cancel()
                return
            }
            guard let json = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let nonce = json["nonce"] as? String,
                  let csr = json["csr"] as? String,
                  outstandingNonces.remove(nonce) != nil else {
                try await MockHTTPConnection.send(status: 400, body: #"{"error":"bad_request"}"#, to: connection)
                connection.cancel()
                return
            }
            let cert = try MockHomeCA.signCSR(csrPEM: csr, caKey: caKey, caCertPEM: caCertPEM)
            let leaf = try CertChain.certificates(fromPEM: cert).first!
            let fingerprint = CertChain.sha256Fingerprint(of: leaf)
            authorizedClients.insert(fingerprint)
            let jwt = try Self.homeAttestation(
                instanceID: instanceID,
                fingerprint: "sha256:\(fingerprint)",
                nonce: nonce,
                key: homeSigningKey
            )
            var response: [String: Any] = [
                "instance_id": instanceID,
                "home_label": homeLabel,
                "client_cert": cert,
                "ca_chain": [caCertPEM],
                "home_attestation": jwt,
                "fingerprint": fingerprint,
            ]
            if let muxPort {
                response["local_endpoints"] = [["host": "127.0.0.1", "port": Int(muxPort), "scope": "loopback"]]
            } else {
                response["local_endpoints"] = []
            }
            let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
            try await MockHTTPConnection.send(status: 200, body: String(data: data, encoding: .utf8)!, to: connection)
            connection.cancel()
        } catch {
            connection.cancel()
        }
    }

    private nonisolated func handleMux(_ connection: NWConnection) async {
        let mux = Multiplexer(sink: { data in
            try await MockHTTPConnection.send(data, to: connection)
        }, role: .listener)
        let receiveTask = Task {
            do {
                while !Task.isCancelled {
                    let chunk = try await MockHome.receive(from: connection)
                    guard let chunk, !chunk.isEmpty else {
                        await mux.tearDown(reason: .transportFailure)
                        return
                    }
                    try await mux.feedInbound(chunk)
                }
            } catch {
                await mux.tearDown(reason: .transportFailure)
            }
        }
        for await stream in mux.incomingStreams {
            Task {
                await handleHTTPRoute(on: stream)
            }
        }
        receiveTask.cancel()
    }

    private nonisolated func handleHTTPRoute(on stream: MuxStream) async {
        do {
            let request = try await Self.readRequest(from: stream)
            let response: (Int, [String: Any])
            if request.headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
                response = (411, ["error": "chunked_unsupported"])
            } else if request.body.count > MockHTTPConnection.maxBodySize {
                response = (413, ["error": "body_too_large"])
            } else if request.method == "GET", request.path == "/app/link/api/status" {
                response = (200, ["status": "ok", "echo": "mock-home"])
            } else if request.method == "GET", request.path.hasPrefix("/echo") {
                let msg = URLComponents(string: request.path)?.queryItems?.first(where: { $0.name == "msg" })?.value ?? ""
                response = (200, ["msg": msg])
            } else if request.method == "POST", request.path == "/app/observer/ingest" {
                response = (200, try Self.ingestResponse(for: request))
            } else {
                response = (404, ["error": "not_found"])
            }
            try await Self.writeJSON(response.1, status: response.0, to: stream)
            try? await stream.close()
        } catch MockHTTPError.bodyTooLarge {
            try? await Self.writeJSON(["error": "body_too_large"], status: 413, to: stream)
            try? await stream.close()
        } catch {
            await stream.reset(reason: .internalError)
        }
    }

    private nonisolated static func readRequest(from stream: MuxStream) async throws -> MockHTTPRequest {
        let inbound = await stream.inbound
        var iterator = inbound.makeAsyncIterator()
        var buffer = Data()
        while !buffer.mockHeaderTerminatorRangeFound {
            guard let chunk = try await iterator.next() else {
                throw MockHTTPError.closed
            }
            buffer.append(chunk)
            if buffer.count > MockHTTPConnection.maxBodySize {
                throw MockHTTPError.bodyTooLarge
            }
        }
        let terminator = buffer.mockHeaderTerminatorRange!
        let headerEnd = terminator.lowerBound
        let bodyStart = terminator.upperBound
        let headerText = String(data: buffer[..<headerEnd], encoding: .utf8) ?? ""
        let lines = headerText.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            throw MockHTTPError.invalidRequest
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let index = line.firstIndex(of: ":") else {
                continue
            }
            headers[String(line[..<index]).lowercased()] = line[line.index(after: index)...]
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength <= MockHTTPConnection.maxBodySize else {
            throw MockHTTPError.bodyTooLarge
        }
        var body = Data(buffer[bodyStart...])
        while body.count < contentLength {
            guard let chunk = try await iterator.next() else {
                throw MockHTTPError.closed
            }
            body.append(chunk)
            if body.count > MockHTTPConnection.maxBodySize {
                throw MockHTTPError.bodyTooLarge
            }
        }
        return MockHTTPRequest(method: parts[0], path: parts[1], headers: headers, body: Data(body.prefix(contentLength)))
    }

    private nonisolated static func writeJSON(_ object: [String: Any], status: Int, to stream: MuxStream) async throws {
        let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let reason = HTTPURLResponse.localizedString(forStatusCode: status)
        var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        try await stream.write(response)
    }

    private nonisolated static func ingestResponse(for request: MockHTTPRequest) throws -> [String: Any] {
        let boundary = request.headers["content-type"]?
            .components(separatedBy: "boundary=")
            .last?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let files = try parseMultipart(body: request.body, boundary: boundary ?? "")
        let total = files.reduce(0) { $0 + ($1["bytes"] as? Int ?? 0) }
        return ["received_bytes": total, "files": files]
    }

    private nonisolated static func parseMultipart(body: Data, boundary: String) throws -> [[String: Any]] {
        guard !boundary.isEmpty else {
            let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            return [["name": "body", "bytes": body.count, "sha256": digest]]
        }
        let marker = Data("--\(boundary)".utf8)
        var cursor = body.startIndex
        var files: [[String: Any]] = []
        while let markerRange = body[cursor...].range(of: marker) {
            cursor = markerRange.upperBound
            if body[cursor...].starts(with: Data("--".utf8)) {
                break
            }
            if body[cursor...].starts(with: Data("\r\n".utf8)) {
                cursor += 2
            }
            guard let headerRange = body[cursor...].range(of: Data("\r\n\r\n".utf8)) else {
                break
            }
            let headerText = String(data: body[cursor..<headerRange.lowerBound], encoding: .utf8) ?? ""
            cursor = headerRange.upperBound
            guard let nextMarker = body[cursor...].range(of: Data("\r\n--\(boundary)".utf8)) else {
                break
            }
            let part = Data(body[cursor..<nextMarker.lowerBound])
            cursor = nextMarker.lowerBound + 2
            let name = headerText.components(separatedBy: "name=\"").dropFirst().first?.components(separatedBy: "\"").first ?? "file"
            let digest = SHA256.hash(data: part).map { String(format: "%02x", $0) }.joined()
            files.append(["name": name, "bytes": part.count, "sha256": digest])
        }
        return files
    }

    private nonisolated static func receive(from connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                continuation.resume(returning: isComplete ? nil : Data())
            }
        }
    }

    private nonisolated static func homeAttestation(
        instanceID: String,
        fingerprint: String,
        nonce: String,
        key: P256.Signing.PrivateKey
    ) throws -> String {
        let now = Int(Date().timeIntervalSince1970)
        let header = ["alg": "ES256", "typ": "home-attest"]
        let payload: [String: Any] = ["sub": instanceID, "iat": now, "exp": now + 300, "fpr": fingerprint, "nonce": nonce]
        let encodedHeader = base64URL(try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
        let encodedPayload = base64URL(try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        let signingInput = "\(encodedHeader).\(encodedPayload)"
        let signature = try key.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(base64URL(Data(signature.rawRepresentation)))"
    }

    private nonisolated static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private nonisolated static func hexBytes(_ value: String) throws -> [UInt8] {
        guard value.count.isMultiple(of: 2) else {
            throw MockHomeError.invalidPairServerFingerprint
        }
        var bytes: [UInt8] = []
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else {
                throw MockHomeError.invalidPairServerFingerprint
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private nonisolated static func encode(_ bytes: [UInt8]) -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var accumulator: UInt64 = 0
        var bitCount = 0
        var output = ""

        for byte in bytes {
            accumulator = (accumulator << 8) | UInt64(byte)
            bitCount += 8

            while bitCount >= 5 {
                bitCount -= 5
                let index = Int((accumulator >> UInt64(bitCount)) & 0x1f)
                output.append(alphabet[index])
                accumulator &= (1 << UInt64(bitCount)) - 1
            }
        }

        if bitCount > 0 {
            let index = Int((accumulator << UInt64(5 - bitCount)) & 0x1f)
            output.append(alphabet[index])
        }

        return output
    }

    private nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum MockHomeError: Error {
    case listenerMissingPort
    case pairServerNotStarted
    case invalidPairServerFingerprint
}

private final class MockAuthorizedClients: @unchecked Sendable {
    // why: TLS verify blocks are synchronous dispatch callbacks; NSLock guards the authorized fingerprint set.
    private let lock = NSLock()
    private var fingerprints = Set<String>()

    func insert(_ fingerprint: String) {
        _ = lock.withLock {
            fingerprints.insert(fingerprint)
        }
    }

    func contains(_ fingerprint: String) -> Bool {
        lock.withLock {
            fingerprints.contains(fingerprint)
        }
    }
}

private final class MockListenerReadyWaiter: @unchecked Sendable {
    // why: NWListener state callbacks run on a dispatch queue while actor start methods await; NSLock serializes one-shot completion.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    private var result: Result<UInt16, Error>?

    func wait() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let result: Result<UInt16, Error>? = lock.withLock {
                if let result = self.result {
                    return result
                }
                self.continuation = continuation
                return nil
            }
            if let result {
                continuation.resume(with: result)
            }
        }
    }

    func complete(_ result: Result<UInt16, Error>) {
        let continuation = lock.withLock {
            guard self.result == nil else {
                return nil as CheckedContinuation<UInt16, Error>?
            }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

private extension Data {
    var mockHeaderTerminatorRange: Range<Data.Index>? {
        range(of: Data("\r\n\r\n".utf8))
    }

    var mockHeaderTerminatorRangeFound: Bool {
        mockHeaderTerminatorRange != nil
    }

    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}
