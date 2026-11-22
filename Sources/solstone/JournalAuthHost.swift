// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Darwin
import Foundation
import os
import Security

private let authHostLog = Logger(subsystem: "app.solstone.observer", category: "auth")

/// The journal page's external-service OAuth broker contract, version 2, read from the copy
/// packaged with the app. Runs over the existing `window.solstoneJournalHost` v2 channel.
struct JournalAuthContract: Equatable, Sendable {
    let version: Int
    let capability: String
    let prepare: String
    let prepared: String
    let authorize: String
    let cancel: String
    let result: String
    let unsupported: String
    /// The packaged JSON bytes, handed to the page script as they are.
    let json: String

    static let supportedVersion = 2

    init?(data: Data?) {
        guard let data, let json = String(data: data, encoding: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = object["version"] as? Int, version == Self.supportedVersion,
              let capability = object["capability"] as? String, !capability.isEmpty,
              let prepare = object["prepare"] as? String, !prepare.isEmpty,
              let prepared = object["prepared"] as? String, !prepared.isEmpty,
              let authorize = object["authorize"] as? String, !authorize.isEmpty,
              let cancel = object["cancel"] as? String, !cancel.isEmpty,
              let result = object["result"] as? String, !result.isEmpty,
              let unsupported = object["unsupported"] as? String, !unsupported.isEmpty
        else { return nil }
        self.version = version
        self.capability = capability
        self.prepare = prepare
        self.prepared = prepared
        self.authorize = authorize
        self.cancel = cancel
        self.result = result
        self.unsupported = unsupported
        self.json = json.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func packaged(appBundle: Bundle = .main) -> JournalAuthContract? {
        JournalAuthContract(data: JournalWebHostContract.packagedBytes(appBundle: appBundle, resource: "auth-host-contract"))
    }
}

/// One validated preference from `auth.prepare`.
enum JournalAuthPreference: Equatable, Sendable {
    case loopback(host: String, path: String, port: UInt16)
    case customScheme(uri: String)
    case other(mode: String)
}

/// Result of evaluating one incoming HTTP/1.1 request on a loopback callback listener.
enum LoopbackCallbackVerdict: Equatable, Sendable {
    case matched(callbackURL: String)
    case reject(statusCode: Int, statusText: String, body: String)
}

/// Abstract loopback listener handle so tests can exercise both real `127.0.0.1` sockets and
/// deterministic fakes without altering protocol validation or session teardown.
protocol LoopbackAuthListening: AnyObject, Sendable {
    var boundPort: UInt16 { get }
    func arm(expectedState: String, onCallback: @escaping @Sendable (String) -> Void)
    func stop()
}

typealias LoopbackListenerFactory = @Sendable (_ host: String, _ path: String, _ port: UInt16) throws -> any LoopbackAuthListening
typealias JournalAuthURLOpener = @MainActor @Sendable (URL) -> Bool

struct JournalAuthValidationError: Error, Equatable, Sendable {
    let reason: String
}

/// Pure parsing, validation, and HTTP callback matching for the desktop loopback OAuth broker.
enum JournalAuthValidation {
    static let maxIDLength = 128
    static let maxPreferences = 16
    static let maxPathBytes = 256
    static let maxAuthorizeURLBytes = 8192
    static let maxStateBytes = 1024
    static let maxRequestHeaderBytes = 8192
    static let minTimeoutSeconds: TimeInterval = 1
    static let maxTimeoutSeconds: TimeInterval = 600
    static let defaultTimeoutSeconds: TimeInterval = 600
    static let successBody = "signed in. you can close this tab and go back to your journal"

    static func validID(_ raw: Any?) -> String? {
        guard let id = raw as? String, !id.isEmpty, id.utf8.count <= maxIDLength else { return nil }
        return id
    }

    static func parsePreferences(_ raw: Any?) -> Result<[JournalAuthPreference], JournalAuthValidationError> {
        guard let list = raw as? [Any], !list.isEmpty, list.count <= maxPreferences else {
            return .failure(JournalAuthValidationError(reason: "invalid_preferences"))
        }
        var parsed: [JournalAuthPreference] = []
        parsed.reserveCapacity(list.count)
        for item in list {
            guard let object = item as? [String: Any],
                  let mode = object["mode"] as? String, !mode.isEmpty
            else {
                return .failure(JournalAuthValidationError(reason: "invalid_preferences"))
            }
            switch mode {
            case "loopback":
                guard let host = object["host"] as? String,
                      host == "127.0.0.1" || host == "localhost"
                else {
                    return .failure(JournalAuthValidationError(reason: "invalid_loopback_host"))
                }
                guard let path = object["path"] as? String, isValidLoopbackPath(path) else {
                    return .failure(JournalAuthValidationError(reason: "invalid_loopback_path"))
                }
                let port: UInt16
                switch object["port"] {
                case nil, is NSNull:
                    port = 0
                case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
                    let doubleVal = number.doubleValue
                    guard doubleVal.isFinite, doubleVal.rounded(.towardZero) == doubleVal else {
                        return .failure(JournalAuthValidationError(reason: "invalid_loopback_port"))
                    }
                    let intVal = number.int64Value
                    if intVal == 0 {
                        port = 0
                    } else if (1024...65535).contains(intVal) {
                        port = UInt16(intVal)
                    } else {
                        return .failure(JournalAuthValidationError(reason: "invalid_loopback_port"))
                    }
                default:
                    return .failure(JournalAuthValidationError(reason: "invalid_loopback_port"))
                }
                parsed.append(.loopback(host: host, path: path, port: port))
            case "custom_scheme":
                guard let uri = object["uri"] as? String, !uri.isEmpty else {
                    return .failure(JournalAuthValidationError(reason: "invalid_custom_scheme"))
                }
                parsed.append(.customScheme(uri: uri))
            default:
                parsed.append(.other(mode: mode))
            }
        }
        return .success(parsed)
    }

    static func isValidLoopbackPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"),
              path.utf8.count >= 1,
              path.utf8.count <= maxPathBytes,
              !path.contains("?"),
              !path.contains("#"),
              !path.contains("..")
        else { return false }
        return path.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }

    /// Strict production validation: `https://` only, <= 8192 bytes, no userinfo `@`, no whitespace
    /// or ASCII control characters, non-empty host.
    static func validateAuthorizeURL(_ raw: Any?) -> URL? {
        guard let text = raw as? String,
              !text.isEmpty,
              text.utf8.count <= maxAuthorizeURLBytes
        else { return nil }
        for scalar in text.unicodeScalars {
            if scalar.value <= 0x20 || scalar.value == 0x7F || scalar.properties.isWhitespace {
                return nil
            }
        }
        guard text.prefix(8).lowercased() == "https://" else { return nil }
        let afterScheme = text.dropFirst(8)
        let authorityEnd = afterScheme.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? afterScheme.endIndex
        let authority = afterScheme[..<authorityEnd]
        guard !authority.isEmpty, !authority.contains("@") else { return nil }
        guard let components = URLComponents(string: text),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host, !host.isEmpty,
              let url = components.url
        else { return nil }
        return url
    }

    static func validateExpectedState(_ raw: Any?) -> String? {
        guard let state = raw as? String,
              !state.isEmpty,
              state.utf8.count <= maxStateBytes,
              state.utf8.allSatisfy({ (0x21...0x7E).contains($0) })
        else { return nil }
        return state
    }

    static func parseTimeoutSeconds(_ raw: Any?) -> Result<TimeInterval, JournalAuthValidationError> {
        switch raw {
        case nil, is NSNull:
            return .success(defaultTimeoutSeconds)
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            let value = number.doubleValue
            guard value.isFinite else { return .failure(JournalAuthValidationError(reason: "invalid_timeout")) }
            return .success(min(max(value, minTimeoutSeconds), maxTimeoutSeconds))
        default:
            return .failure(JournalAuthValidationError(reason: "invalid_timeout"))
        }
    }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }

    static func percentDecode(_ value: String) -> String? {
        let bytes = Array(value.utf8)
        var decoded: [UInt8] = []
        decoded.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte == 0x2B { // '+'
                decoded.append(0x20)
                i += 1
            } else if byte == 0x25 { // '%'
                guard i + 2 < bytes.count,
                      let hi = hexNibble(bytes[i + 1]),
                      let lo = hexNibble(bytes[i + 2])
                else { return nil }
                decoded.append((hi << 4) | lo)
                i += 3
            } else {
                decoded.append(byte)
                i += 1
            }
        }
        return String(bytes: decoded, encoding: .utf8)
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    static func parseQueryRefusingDuplicates(_ query: String) -> [String: String]? {
        var params: [String: String] = [:]
        for rawPair in query.split(separator: "&", omittingEmptySubsequences: false) {
            if rawPair.isEmpty { continue }
            let keyPart: Substring
            let valuePart: Substring
            if let eq = rawPair.firstIndex(of: "=") {
                keyPart = rawPair[..<eq]
                valuePart = rawPair[rawPair.index(after: eq)...]
            } else {
                keyPart = rawPair
                valuePart = ""
            }
            guard let key = percentDecode(String(keyPart)),
                  let value = percentDecode(String(valuePart))
            else { return nil }
            if params[key] != nil {
                return nil
            }
            params[key] = value
        }
        return params
    }

    static func evaluateLoopbackHTTPRequest(
        _ rawBytes: Data,
        expectedHost: String,
        boundPort: UInt16,
        expectedPath: String,
        expectedState: String?
    ) -> LoopbackCallbackVerdict {
        let badRequest = LoopbackCallbackVerdict.reject(statusCode: 400, statusText: "Bad Request", body: "bad request")
        let notFound = LoopbackCallbackVerdict.reject(statusCode: 404, statusText: "Not Found", body: "not found")
        guard rawBytes.count <= maxRequestHeaderBytes,
              let headerEnd = rawBytes.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: rawBytes[..<headerEnd.lowerBound], encoding: .utf8)
        else {
            return badRequest
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { return badRequest }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == "GET",
              parts[2].hasPrefix("HTTP/1.")
        else { return badRequest }

        let target = String(parts[1])
        guard target.hasPrefix("/"),
              !target.contains("#"),
              target.utf8.allSatisfy({ (0x21...0x7E).contains($0) })
        else { return badRequest }

        // Require exactly one Host header matching `<expectedHost>:<boundPort>`.
        let expectedHostHeader = "\(expectedHost):\(boundPort)"
        var matchedHosts: [String] = []
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { return badRequest }
            let name = line[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            if name.lowercased() == "host" {
                matchedHosts.append(value)
            }
        }
        guard matchedHosts.count == 1, matchedHosts[0] == expectedHostHeader else {
            return badRequest
        }

        let pathPart: String
        let queryPart: String?
        if let q = target.firstIndex(of: "?") {
            pathPart = String(target[..<q])
            queryPart = String(target[target.index(after: q)...])
        } else {
            pathPart = target
            queryPart = nil
        }

        guard pathPart == expectedPath else { return notFound }
        guard let expectedState, let queryPart, !queryPart.isEmpty else { return badRequest }
        guard let params = parseQueryRefusingDuplicates(queryPart) else { return badRequest }
        guard let state = params["state"], constantTimeEqual(state, expectedState) else { return badRequest }
        guard params["code"] != nil || params["error"] != nil else { return badRequest }

        return .matched(callbackURL: "http://\(expectedHost):\(boundPort)\(target)")
    }

    static func httpResponseData(statusCode: Int, statusText: String, body: String) -> Data {
        let bodyData = Data(body.utf8)
        let header =
            "HTTP/1.1 \(statusCode) \(statusText)\r\n" +
            "Content-Type: text/plain; charset=utf-8\r\n" +
            "Cache-Control: no-store\r\n" +
            "X-Content-Type-Options: nosniff\r\n" +
            "Content-Length: \(bodyData.count)\r\n" +
            "Connection: close\r\n" +
            "\r\n"
        var data = Data(header.utf8)
        data.append(bodyData)
        return data
    }

    static func randomSessionID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            for i in bytes.indices {
                bytes[i] = UInt8.random(in: 0...255, using: &rng)
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Hardened POSIX loopback TCP listener bound strictly to `127.0.0.1:<port>`.
final class LoopbackOAuthListener: LoopbackAuthListening, @unchecked Sendable {
    enum BindError: Error {
        case socketFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case pipeFailed(Int32)
    }

    let boundPort: UInt16
    private let expectedHost: String
    private let expectedPath: String
    private let lock = NSLock()
    private var listenFD: Int32
    private var wakeReadFD: Int32
    private var wakeWriteFD: Int32
    private var stopped = false
    private var consumed = false
    private var expectedState: String?
    private var onCallback: (@Sendable (String) -> Void)?
    private let acceptQueue = DispatchQueue(label: "app.solstone.observer.auth.accept", qos: .userInitiated)
    private let acceptGroup = DispatchGroup()
    private let connectionQueue = DispatchQueue(label: "app.solstone.observer.auth.conn", qos: .userInitiated, attributes: .concurrent)
    private let connectionSlots = DispatchSemaphore(value: 16)

    init(host: String, path: String, port: UInt16) throws {
        self.expectedHost = host
        self.expectedPath = path

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BindError.socketFailed(errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        var nosigpipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            Darwin.close(fd)
            throw BindError.bindFailed(err)
        }
        guard Darwin.listen(fd, 16) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw BindError.listenFailed(err)
        }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.getsockname(fd, sockaddrPtr, &addrLen)
            }
        }
        guard nameResult == 0 else {
            let err = errno
            Darwin.close(fd)
            throw BindError.bindFailed(err)
        }
        self.boundPort = UInt16(bigEndian: boundAddr.sin_port)

        var pipeFDs: [Int32] = [-1, -1]
        guard Darwin.pipe(&pipeFDs) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw BindError.pipeFailed(err)
        }
        _ = fcntl(pipeFDs[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(pipeFDs[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(pipeFDs[0], F_SETFL, O_NONBLOCK)
        _ = fcntl(pipeFDs[1], F_SETFL, O_NONBLOCK)

        self.listenFD = fd
        self.wakeReadFD = pipeFDs[0]
        self.wakeWriteFD = pipeFDs[1]

        acceptGroup.enter()
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    deinit {
        stop()
    }

    func arm(expectedState: String, onCallback: @escaping @Sendable (String) -> Void) {
        lock.lock()
        self.expectedState = expectedState
        self.onCallback = onCallback
        lock.unlock()
    }

    func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            acceptGroup.wait()
            return
        }
        stopped = true
        let wfd = wakeWriteFD
        wakeWriteFD = -1
        onCallback = nil
        expectedState = nil
        lock.unlock()

        if wfd >= 0 {
            var byte: UInt8 = 1
            _ = Darwin.write(wfd, &byte, 1)
            Darwin.close(wfd)
        }
        acceptGroup.wait()
    }

    private func acceptLoop() {
        defer {
            lock.lock()
            let lfd = listenFD
            listenFD = -1
            let rfd = wakeReadFD
            wakeReadFD = -1
            let wfd = wakeWriteFD
            wakeWriteFD = -1
            stopped = true
            lock.unlock()
            if lfd >= 0 { Darwin.close(lfd) }
            if rfd >= 0 { Darwin.close(rfd) }
            if wfd >= 0 { Darwin.close(wfd) }
            acceptGroup.leave()
        }
        while true {
            lock.lock()
            let isStopped = stopped
            let lfd = listenFD
            let rfd = wakeReadFD
            lock.unlock()
            if isStopped || lfd < 0 || rfd < 0 { break }

            var fds = [
                pollfd(fd: lfd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: rfd, events: Int16(POLLIN), revents: 0),
            ]
            let rc = Darwin.poll(&fds, 2, -1)
            if rc < 0 {
                if errno == EINTR { continue }
                break
            }
            if (fds[1].revents & Int16(POLLIN | POLLHUP | POLLNVAL | POLLERR)) != 0 {
                break
            }
            if (fds[0].revents & Int16(POLLNVAL | POLLERR)) != 0 {
                break
            }
            if (fds[0].revents & Int16(POLLIN)) != 0 {
                let clientFD = Darwin.accept(lfd, nil, nil)
                if clientFD < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    break
                }
                if connectionSlots.wait(timeout: .now()) == .timedOut {
                    let busy = JournalAuthValidation.httpResponseData(
                        statusCode: 503,
                        statusText: "Service Unavailable",
                        body: "busy"
                    )
                    Self.writeAll(fd: clientFD, data: busy)
                    Darwin.close(clientFD)
                    continue
                }
                connectionQueue.async { [weak self] in
                    defer { self?.connectionSlots.signal() }
                    self?.handleClient(fd: clientFD)
                }
            }
        }
    }

    private func handleClient(fd: Int32) {
        defer { Darwin.close(fd) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var nosigpipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let requestBytes = Self.readRequestHeaders(fd: fd, limit: JournalAuthValidation.maxRequestHeaderBytes) else {
            let response = JournalAuthValidation.httpResponseData(statusCode: 400, statusText: "Bad Request", body: "bad request")
            Self.writeAll(fd: fd, data: response)
            return
        }

        lock.lock()
        let activeState = (stopped || consumed) ? nil : expectedState
        lock.unlock()

        let verdict = JournalAuthValidation.evaluateLoopbackHTTPRequest(
            requestBytes,
            expectedHost: expectedHost,
            boundPort: boundPort,
            expectedPath: expectedPath,
            expectedState: activeState
        )

        switch verdict {
        case .reject(let statusCode, let statusText, let body):
            let response = JournalAuthValidation.httpResponseData(statusCode: statusCode, statusText: statusText, body: body)
            Self.writeAll(fd: fd, data: response)
        case .matched(let callbackURL):
            lock.lock()
            let canClaim = !stopped && !consumed && expectedState != nil
            let deliver = canClaim ? onCallback : nil
            if canClaim {
                consumed = true
                onCallback = nil
                expectedState = nil
            }
            lock.unlock()

            if let deliver {
                let response = JournalAuthValidation.httpResponseData(
                    statusCode: 200,
                    statusText: "OK",
                    body: JournalAuthValidation.successBody
                )
                Self.writeAll(fd: fd, data: response)
                stop()
                deliver(callbackURL)
            } else {
                let response = JournalAuthValidation.httpResponseData(statusCode: 400, statusText: "Bad Request", body: "bad request")
                Self.writeAll(fd: fd, data: response)
            }
        }
    }

    private static func readRequestHeaders(fd: Int32, limit: Int) -> Data? {
        var buffer = Data()
        buffer.reserveCapacity(1024)
        var chunk = [UInt8](repeating: 0, count: 1024)
        let delimiter = Data("\r\n\r\n".utf8)
        while buffer.count <= limit {
            let remaining = (limit + 1) - buffer.count
            let toRead = min(chunk.count, remaining)
            let n = Darwin.recv(fd, &chunk, toRead, 0)
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            buffer.append(contentsOf: chunk[..<n])
            if buffer.count > limit {
                return nil
            }
            if buffer.range(of: delimiter) != nil {
                return buffer
            }
        }
        return buffer.range(of: delimiter) != nil ? buffer : nil
    }

    private static func writeAll(fd: Int32, data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.send(fd, base.advanced(by: offset), data.count - offset, 0)
                if written < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if written == 0 { break }
                offset += written
            }
        }
    }
}

/// Manages the single active OAuth browser-callback brokerage session for a macOS journal window.
/// Holds zero tokens or PKCE verifiers and never logs `callback_url`.
@MainActor
final class JournalAuthHost {
    let contract: JournalAuthContract
    private let openExternalURL: JournalAuthURLOpener
    private let listenerFactory: LoopbackListenerFactory
    private let idleTimeout: TimeInterval

    private struct ActiveSession {
        let sessionID: String
        let host: String
        let path: String
        let listener: any LoopbackAuthListening
        var authorizingID: String?
        var continuation: CheckedContinuation<[String: Any], Never>?
        var timerTask: Task<Void, Never>?
    }

    private var active: ActiveSession?

    init(
        contract: JournalAuthContract,
        openExternalURL: @escaping JournalAuthURLOpener = { NSWorkspace.shared.open($0) },
        listenerFactory: @escaping LoopbackListenerFactory = { host, path, port in
            try LoopbackOAuthListener(host: host, path: path, port: port)
        },
        idleTimeout: TimeInterval = JournalAuthValidation.defaultTimeoutSeconds
    ) {
        self.contract = contract
        self.openExternalURL = openExternalURL
        self.listenerFactory = listenerFactory
        self.idleTimeout = idleTimeout
    }

    func handles(type: String) -> Bool {
        type == contract.prepare || type == contract.authorize || type == contract.cancel
    }

    func handle(_ message: [String: Any], type: String) async -> [String: Any] {
        switch type {
        case contract.prepare:
            return prepare(message)
        case contract.authorize:
            return await authorize(message)
        case contract.cancel:
            return cancel(message)
        default:
            let id = message["id"] as? String ?? ""
            return ["type": contract.unsupported, "id": id]
        }
    }

    /// Cancels and tears down any active prepared or authorizing session, settling any pending
    /// `auth.authorize` Promise with `cancelled`.
    func tearDown() {
        settleActive(outcome: "cancelled")
    }

    private func prepare(_ message: [String: Any]) -> [String: Any] {
        guard let id = JournalAuthValidation.validID(message["id"]) else {
            return ["type": contract.unsupported, "id": ""]
        }
        func reply(_ outcome: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            var body: [String: Any] = ["type": contract.prepared, "id": id, "outcome": outcome]
            for (k, v) in extra { body[k] = v }
            return body
        }

        let preferences: [JournalAuthPreference]
        switch JournalAuthValidation.parsePreferences(message["preferences"]) {
        case .success(let parsed):
            preferences = parsed
        case .failure(let error):
            return reply("refused", ["reason": error.reason])
        }

        // Single active session per window: tear down any prior idle or in-flight session first
        // so an earlier `auth.authorize` settles as `cancelled` and any fixed port is freed.
        settleActive(outcome: "cancelled")

        var sawUnavailable = false
        for pref in preferences {
            guard case .loopback(let host, let path, let port) = pref else {
                continue
            }
            do {
                let listener = try listenerFactory(host, path, port)
                let sessionID = JournalAuthValidation.randomSessionID()
                let boundPort = listener.boundPort
                let redirectURI = "http://\(host):\(boundPort)\(path)"
                let timerTask = startTimer(sessionID: sessionID, seconds: idleTimeout, isAuthorizing: false)
                active = ActiveSession(
                    sessionID: sessionID,
                    host: host,
                    path: path,
                    listener: listener,
                    authorizingID: nil,
                    continuation: nil,
                    timerTask: timerTask
                )
                authHostLog.notice("auth-host: prepared loopback session port=\(boundPort, privacy: .public)")
                return reply("ready", [
                    "session_id": sessionID,
                    "mode": "loopback",
                    "redirect_uri": redirectURI,
                ])
            } catch {
                sawUnavailable = true
                continue
            }
        }

        if sawUnavailable {
            return reply("unavailable", ["reason": "port_unavailable"])
        }
        return reply("no_compatible_mode")
    }

    private func authorize(_ message: [String: Any]) async -> [String: Any] {
        guard let id = JournalAuthValidation.validID(message["id"]) else {
            return ["type": contract.unsupported, "id": ""]
        }
        func result(_ outcome: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            var body: [String: Any] = ["type": contract.result, "id": id, "outcome": outcome]
            for (k, v) in extra { body[k] = v }
            return body
        }

        guard let sessionID = message["session_id"] as? String, !sessionID.isEmpty else {
            return result("refused", ["reason": "invalid_session"])
        }
        guard let authorizeURL = JournalAuthValidation.validateAuthorizeURL(message["authorize_url"]) else {
            return result("refused", ["reason": "invalid_authorize_url"])
        }
        guard let expectedState = JournalAuthValidation.validateExpectedState(message["expected_state"]) else {
            return result("refused", ["reason": "invalid_state"])
        }
        let timeoutSeconds: TimeInterval
        switch JournalAuthValidation.parseTimeoutSeconds(message["timeout_seconds"]) {
        case .success(let value):
            timeoutSeconds = value
        case .failure(let error):
            return result("refused", ["reason": error.reason])
        }

        guard let current = active, current.sessionID == sessionID, current.authorizingID == nil else {
            return result("refused", ["reason": "invalid_session"])
        }

        current.timerTask?.cancel()
        active?.authorizingID = id
        active?.timerTask = startTimer(sessionID: sessionID, seconds: timeoutSeconds, isAuthorizing: true)

        return await withCheckedContinuation { continuation in
            active?.continuation = continuation
            current.listener.arm(expectedState: expectedState) { [weak self] callbackURL in
                Task { @MainActor [weak self] in
                    self?.completeFromCallback(sessionID: sessionID, callbackURL: callbackURL)
                }
            }
            if !openExternalURL(authorizeURL) {
                authHostLog.notice("auth-host: system browser open failed")
                settleIfMatching(sessionID: sessionID, outcome: "error", reason: "browser_open_failed")
            }
        }
    }

    private func cancel(_ message: [String: Any]) -> [String: Any] {
        guard let id = JournalAuthValidation.validID(message["id"]) else {
            return ["type": contract.unsupported, "id": ""]
        }
        let requestedSessionID = message["session_id"] as? String
        if let current = active {
            if requestedSessionID == nil || requestedSessionID?.isEmpty == true || current.sessionID == requestedSessionID {
                settleActive(outcome: "cancelled")
            }
        }
        return ["type": contract.result, "id": id, "outcome": "cancelled"]
    }

    private func startTimer(sessionID: String, seconds: TimeInterval, isAuthorizing: Bool) -> Task<Void, Never> {
        let clampedNanos = UInt64(max(0.01, seconds) * 1_000_000_000)
        return Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: clampedNanos)
            } catch {
                return
            }
            guard let self else { return }
            if isAuthorizing {
                authHostLog.notice("auth-host: session timed out")
                self.settleIfMatching(sessionID: sessionID, outcome: "timeout")
            } else {
                self.settleIfMatching(sessionID: sessionID, outcome: "cancelled")
            }
        }
    }

    private func completeFromCallback(sessionID: String, callbackURL: String) {
        guard let current = active, current.sessionID == sessionID else { return }
        active = nil
        current.timerTask?.cancel()
        current.listener.stop()
        authHostLog.notice("auth-host: callback delivered outcome=callback")
        if let authorizeID = current.authorizingID, let continuation = current.continuation {
            continuation.resume(returning: [
                "type": contract.result,
                "id": authorizeID,
                "outcome": "callback",
                "callback_url": callbackURL,
            ])
        }
    }

    private func settleIfMatching(sessionID: String, outcome: String, reason: String? = nil) {
        guard active?.sessionID == sessionID else { return }
        settleActive(outcome: outcome, reason: reason)
    }

    private func settleActive(outcome: String, reason: String? = nil) {
        guard let current = active else { return }
        active = nil
        current.timerTask?.cancel()
        current.listener.stop()
        if let authorizeID = current.authorizingID, let continuation = current.continuation {
            var body: [String: Any] = [
                "type": contract.result,
                "id": authorizeID,
                "outcome": outcome,
            ]
            if let reason { body["reason"] = reason }
            continuation.resume(returning: body)
        }
    }
}
