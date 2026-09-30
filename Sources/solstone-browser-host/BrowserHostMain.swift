// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Darwin
import Dispatch
import Foundation

@main
enum BrowserHostMain {
    static func main() {
        let allowlist: NativeHostAllowlist
        do {
            let authorityURL = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/vendor/contracts/native-browser/authority.json")
            allowlist = try NativeHostAllowlist(authorityJSON: Data(contentsOf: authorityURL))
        } catch {
            reject("argv_rejected")
        }

        let identity: NativeHostIdentity
        do {
            identity = try NativeHostArgv.parse(Array(CommandLine.arguments.dropFirst()), allowlist: allowlist)
        } catch {
            reject("argv_rejected")
        }

        let socketURL = NativeHostPaths.socketURL()
        let socketPath = socketURL.path
        guard NativeHostSocketPath.fits(socketPath) else { reject("socket_path_too_long") }
        let connection = NativeHostEndpoint.connect(path: socketPath)
        guard let descriptor = connection.descriptor else {
            if connection.error == ENOENT || connection.error == ECONNREFUSED {
                writeUnavailableHelloAck()
            }
            return
        }
        defer { Darwin.close(descriptor) }

        let stop = NativeHostStopFlag()
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        source.setEventHandler { stop.stop() }
        source.resume()
        defer { source.cancel() }

        let context: [String: String] = [
            "type": "local_hello",
            "brand": identity.brandHint.rawValue,
            "mode": identity.mode.rawValue
        ]
        guard let contextBytes = try? JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]),
              (try? NativeHostFrameIO.writeFrame(contextBytes, to: descriptor, direction: .control,
                                                timeoutMs: BrowserHostLimits.helperFallback.handshakeMs,
                                                shouldCancel: { stop.value })) != nil else {
            return
        }

        relay(stdin: STDIN_FILENO, socket: descriptor, stop: stop)
    }

    private static func relay(stdin: Int32, socket: Int32, stop: NativeHostStopFlag) {
        var reducer = NativeHostRelayReducer()
        var stdinDecoder = NativeHostFrameDecoder(direction: .extensionToHost, initialControl: true)
        var stdinBuffer = [UInt8](repeating: 0, count: 65536)
        guard (try? NativeHostFrameIO.makeNonblocking(stdin)) != nil else { return }
        let handshakeStarted = DispatchTime.now().uptimeNanoseconds
        var receivedFirstFrame = false

        while true {
            if stop.value {
                _ = reducer.reduce(.sigterm)
                return
            }
            var descriptors = [
                pollfd(fd: socket, events: Int16(POLLIN), revents: 0),
                pollfd(fd: stdin, events: Int16(POLLIN), revents: 0)
            ]
            let ready = poll(&descriptors, nfds_t(descriptors.count), 250)
            if stop.value {
                _ = reducer.reduce(.sigterm)
                return
            }
            if ready < 0 {
                if errno == EINTR { continue }
                _ = reducer.reduce(.appLoss)
                return
            }
            do { try stdinDecoder.checkDeadline() }
            catch { return }
            if !receivedFirstFrame,
               (DispatchTime.now().uptimeNanoseconds &- handshakeStarted) / 1_000_000 >= BrowserHostLimits.helperFallback.handshakeMs {
                return
            }
            if ready == 0 { continue }

            // Drain host output first so shutdown and unsupported replies stay terminal
            // even when native-messaging stdin also has buffered input.
            if descriptors[0].revents & (Int16(POLLIN) | Int16(POLLHUP) | Int16(POLLERR)) != 0 {
                do {
                    guard let response = try NativeHostFrameIO.readFrame(
                        from: socket,
                        direction: .hostToExtension,
                        shouldCancel: { stop.value }
                    ) else {
                        _ = reducer.reduce(.appLoss)
                        return
                    }
                    try NativeHostFrameIO.writeFrame(
                        response.body,
                        to: STDOUT_FILENO,
                        direction: .hostToExtension,
                        timeoutMs: BrowserHostLimits.helperFallback.handshakeMs,
                        shouldCancel: { stop.value }
                    )
                    if isBye(response.body) {
                        _ = reducer.reduce(.hostBye)
                        return
                    }
                    if isUnsupported(response.body) {
                        _ = reducer.reduce(.hostUnsupported)
                        return
                    }
                    _ = reducer.reduce(.hostAccepted)
                } catch {
                    _ = reducer.reduce(.forwardFailure)
                    return
                }
            }

            if stop.value {
                _ = reducer.reduce(.sigterm)
                return
            }
            if descriptors[1].revents & (Int16(POLLIN) | Int16(POLLHUP) | Int16(POLLERR)) != 0 {
                let amount = stdinBuffer.withUnsafeMutableBytes { raw in
                    Darwin.read(stdin, raw.baseAddress!, raw.count)
                }
                if amount == 0 {
                    _ = reducer.reduce(.stdinEOF)
                    return
                }
                if amount < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    _ = reducer.reduce(.forwardFailure)
                    return
                }
                do {
                    let chunk = Data(stdinBuffer[0..<amount])
                    let frames = try stdinDecoder.append(chunk)
                    for frameBody in frames {
                        receivedFirstFrame = true
                        try NativeHostFrameIO.writeFrame(
                            frameBody,
                            to: socket,
                            direction: .extensionToHost,
                            shouldCancel: { stop.value }
                        )
                        _ = reducer.reduce(.extensionFrame)
                    }
                } catch {
                    _ = reducer.reduce(.forwardFailure)
                    return
                }
            }
        }
    }

    private static func isBye(_ bytes: Data) -> Bool { messageType(bytes) == "bye" }

    private static func isUnsupported(_ bytes: Data) -> Bool { messageType(bytes) == "unsupported" }

    private static func messageType(_ bytes: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
        return object["type"] as? String
    }

private final class NativeHostStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var value: Bool { lock.withLock { stopped } }
    func stop() { lock.withLock { stopped = true } }
}

    private static func reject(_ code: String) -> Never {
        let json = Data("{\"code\":\"\(code)\"}".utf8)
        try? NativeHostFrameIO.writeFrame(json, to: STDOUT_FILENO, direction: .control)
        exit(1)
    }

    private static func writeUnavailableHelloAck() {
        let json = Data("{\"type\":\"hello_ack\",\"capture\":\"unavailable\",\"delivery\":\"unknown\",\"freshness_ms\":0,\"destination_generation\":null,\"period_id\":null,\"custody\":{\"full\":false,\"stale\":false},\"version\":\"1.1.0\"}".utf8)
        try? NativeHostFrameIO.writeFrame(json, to: STDOUT_FILENO, direction: .hostToExtension)
    }
}

#else
import Darwin

@main
enum BrowserHostDisabled {
    static func main() { exit(78) }
}
#endif
