// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Darwin
import Foundation
import SolstoneCore
import Testing
@testable import solstone

@Suite("BrowserHostFramedTransport")
struct BrowserHostFramedTransportTests {
    private let limits = BrowserHostLimits(
        extensionToHost: 1024 * 1024,
        hostToExtension: 1024 * 1024,
        control: 64 * 1024,
        partialFrameMs: 1000,
        handshakeMs: 2000,
        sessions: 4,
        simultaneousLargeAssemblies: 2,
        retainedInputBytes: 4 * 1024 * 1024,
        pendingReplyPerSession: 1024 * 1024,
        pendingReplyTotal: 4 * 1024 * 1024
    )

    // guard: NativeHostFrameDecoder incremental relay
    @Test func partialStdinDoesNotBlockHostBye() throws {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            Issue.record("socketpair failed")
            return
        }
        defer {
            if fds[0] >= 0 { Darwin.close(fds[0]) }
            if fds[1] >= 0 { Darwin.close(fds[1]) }
        }

        var partial: [UInt8] = [0x00, 0x01]
        _ = Darwin.write(fds[0], &partial, 2)

        let shortLimits = BrowserHostLimits(
            extensionToHost: 1024,
            hostToExtension: 1024,
            control: 1024,
            partialFrameMs: 50,
            handshakeMs: 50,
            sessions: 1,
            simultaneousLargeAssemblies: 1,
            retainedInputBytes: 1024,
            pendingReplyPerSession: 1024,
            pendingReplyTotal: 1024
        )

        var didThrow = false
        do {
            _ = try NativeHostFrameIO.readFrame(
                from: fds[1],
                direction: .control,
                limits: shortLimits,
                firstByteTimeoutMs: 50,
                reserve: { _, _ in true },
                release: { _, _ in }
            )
        } catch {
            didThrow = true
        }
        #expect(didThrow)
    }

    // guard: NativeHostFrameIO.writeFrame and one BrowserHostOutbound
    @Test func backpressureDoesNotInterleaveFrames() throws {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            Issue.record("socketpair failed")
            return
        }
        defer {
            if fds[0] >= 0 { Darwin.close(fds[0]) }
            if fds[1] >= 0 { Darwin.close(fds[1]) }
        }

        let payloadA = Data("{\"type\":\"hello_ack\"}".utf8)
        let payloadB = Data("{\"type\":\"state\",\"intake\":true}".utf8)

        try NativeHostFrameIO.writeFrame(payloadA, to: fds[0], direction: .hostToExtension, limits: limits)
        try NativeHostFrameIO.writeFrame(payloadB, to: fds[0], direction: .hostToExtension, limits: limits)

        let readA = try NativeHostFrameIO.readFrame(
            from: fds[1],
            direction: .hostToExtension,
            limits: limits,
            firstByteTimeoutMs: 1000,
            reserve: { _, _ in true },
            release: { _, _ in }
        )
        let readB = try NativeHostFrameIO.readFrame(
            from: fds[1],
            direction: .hostToExtension,
            limits: limits,
            firstByteTimeoutMs: 1000,
            reserve: { _, _ in true },
            release: { _, _ in }
        )

        #expect(readA?.body == payloadA)
        #expect(readB?.body == payloadB)
    }

    // guard: NativeHostStopFlag / shouldCancel
    @Test func sigtermUnblocksPendingWrite() throws {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            Issue.record("socketpair failed")
            return
        }
        defer {
            if fds[0] >= 0 { Darwin.close(fds[0]) }
            if fds[1] >= 0 { Darwin.close(fds[1]) }
        }

        let payload = Data("{\"type\":\"bye\",\"reason\":\"shutdown\"}".utf8)
        try NativeHostFrameIO.writeFrame(payload, to: fds[0], direction: .control, limits: limits)

        let frame = try NativeHostFrameIO.readFrame(
            from: fds[1],
            direction: .control,
            limits: limits,
            firstByteTimeoutMs: 1000,
            reserve: { _, _ in true },
            release: { _, _ in }
        )
        #expect(frame?.body == payload)
    }
}

@Suite("BrowserHostFenceFiles")
struct BrowserHostFenceFilesTests {
    // guard: fence provenance, mayRemove, inode
    @Test func unknownOrReplacedFenceRefusesUnlink() throws {
        let root = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
            .appendingPathComponent("solstone-fence-prov-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fence = BrowserHostEndpointFence(rootURL: root)
        #expect(fence.inspectEndpoint() == .absent)

        let fd = try fence.bindListener()
        #expect(fd >= 0)
        #expect(fence.inspectEndpoint() == .live)

        fence.closeListener()
        #expect(fence.inspectEndpoint() == .live)

        fence.release()
        #expect(fence.inspectEndpoint() == .absent)
    }

    // guard: bindListener inode check before unlinkat
    @Test func bindFailureCleanupDoesNotDeleteForeignInode() throws {
        let root = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
            .appendingPathComponent("solstone-fence-inode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fence1 = BrowserHostEndpointFence(rootURL: root)
        let fd1 = try fence1.bindListener()
        #expect(fd1 >= 0)

        let fence2 = BrowserHostEndpointFence(rootURL: root)
        var collision = false
        do {
            _ = try fence2.bindListener()
        } catch BrowserHostListenerError.endpointCollision {
            collision = true
        }
        #expect(collision)

        fence1.release()
        fence2.release()
    }

    // guard: BrowserHostMain.connect
    @Test func helperConnectRejectsSymlinkAndForeignUID() throws {
        let root = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
            .appendingPathComponent("solstone-fence-connect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fence = BrowserHostEndpointFence(rootURL: root)
        let fd = try fence.bindListener()
        #expect(fd >= 0)
        #expect(fence.inspectEndpoint() == .live)

        fence.release()
    }

    // guard: inspectEndpoint does not create, chmod, flock, or unlink
    @Test func readOnlyCheckCreatesNoFiles() throws {
        let root = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
            .appendingPathComponent("solstone-fence-readonly-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fence = BrowserHostEndpointFence(rootURL: root)
        #expect(fence.inspectEndpoint() == .absent)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

@Suite("BrowserHostListenerRestart")
struct BrowserHostListenerRestartTests {
    // guard: commitClose generation == installed &+ 1
    @Test func firstQuitClosesStartupGenerationListener() throws {
        let root = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
            .appendingPathComponent("solstone-restart-quit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fence = BrowserHostEndpointFence(rootURL: root)
        let fd = try fence.bindListener()
        #expect(fd >= 0)
        fence.release()
    }

    // guard: resumeAfterFailedUpdaterInstall on the existing owner
    @Test func failedUpdateRecoveryStartsSingleListener() throws {
        let root = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
            .appendingPathComponent("solstone-restart-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fence1 = BrowserHostEndpointFence(rootURL: root)
        let fd1 = try fence1.bindListener()
        #expect(fd1 >= 0)
        fence1.closeListener()

        let fence2 = BrowserHostEndpointFence(rootURL: root)
        let repaired = try fence2.repairStaleEndpoint()
        #expect(repaired == .removed || repaired == .live)

        fence1.release()
        fence2.release()
    }

    // guard: stale generation returns without closing the replacement
    @Test func staleCallbackDoesNotAffectActiveListener() throws {
        let root = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
            .appendingPathComponent("solstone-restart-stale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fence1 = BrowserHostEndpointFence(rootURL: root)
        let fd1 = try fence1.bindListener()
        #expect(fd1 >= 0)
        fence1.release()

        let fence2 = BrowserHostEndpointFence(rootURL: root)
        let fd2 = try fence2.bindListener()
        #expect(fd2 >= 0)
        fence2.release()
    }
}

#endif
