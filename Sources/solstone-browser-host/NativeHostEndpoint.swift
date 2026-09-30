// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW
import Darwin
import Foundation

public enum NativeHostEndpoint {
    public static func ancestorsAreSafe(_ path: String, allowMissing: Bool = false) -> Bool {
        var cursor = URL(fileURLWithPath: "/")
        for component in path.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            var info = stat()
            guard lstat(cursor.path, &info) == 0 else {
                return allowMissing && errno == ENOENT
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == geteuid() || info.st_uid == 0 else { return false }
            // A root-owned sticky temporary parent protects the owned child entry.
            let stickyParent = info.st_uid == 0 && (info.st_mode & S_ISVTX) != 0
            guard (info.st_mode & 0o022) == 0 || stickyParent else { return false }
        }
        return true
    }

    public static func address(_ path: String) -> sockaddr_un? {
        guard NativeHostSocketPath.fits(path) else { return nil }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: NativeHostSocketPath.sunPathBytes) { chars in
                for (index, byte) in bytes.enumerated() { chars[index] = CChar(bitPattern: byte) }
                chars[bytes.count] = 0
            }
        }
        return address
    }

    /// No page bytes are transmitted until the endpoint and connected server UID agree.
    public static func connect(path: String) -> (descriptor: Int32?, error: Int32) {
        guard var address = address(path) else { return (nil, ENAMETOOLONG) }
        let parent = (path as NSString).deletingLastPathComponent
        guard ancestorsAreSafe(parent) else { return (nil, EPERM) }
        var directory = stat()
        var endpoint = stat()
        guard lstat(parent, &directory) == 0 else { return (nil, errno) }
        guard directory.st_uid == geteuid(), (directory.st_mode & S_IFMT) == S_IFDIR,
              directory.st_mode & 0o777 == 0o700 else { return (nil, EPERM) }
        guard lstat(path, &endpoint) == 0 else { return (nil, errno) }
        guard endpoint.st_uid == geteuid(), (endpoint.st_mode & S_IFMT) == S_IFSOCK,
              endpoint.st_mode & 0o777 == 0o600 else { return (nil, EPERM) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return (nil, errno) }
        var retained = false
        defer { if !retained { Darwin.close(fd) } }
        do { try NativeHostFrameIO.makeNonblocking(fd) }
        catch { return (nil, EIO) }
        var noSigPipe: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            return (nil, errno)
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            let failure = errno
            guard failure == EINPROGRESS || failure == EAGAIN else { return (nil, failure) }
            var ready = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&ready, 1, 1_000) > 0 else { return (nil, ETIMEDOUT) }
            var socketError: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0 else { return (nil, errno) }
            guard socketError == 0 else { return (nil, socketError) }
        }
        var uid: uid_t = 0
        var gid: gid_t = 0
        var afterDirectory = stat()
        var afterEndpoint = stat()
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid(),
              ancestorsAreSafe(parent),
              lstat(parent, &afterDirectory) == 0, lstat(path, &afterEndpoint) == 0,
              same(directory, afterDirectory), same(endpoint, afterEndpoint) else { return (nil, EPERM) }
        retained = true
        return (fd, 0)
    }

    private static func same(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_uid == rhs.st_uid && lhs.st_mode == rhs.st_mode
    }
}
#endif
