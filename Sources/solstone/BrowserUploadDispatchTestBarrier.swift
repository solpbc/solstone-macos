// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW && SOLSTONE_BROWSER_DEVELOPMENT_HOST
import Darwin
import Foundation

/// A one-use, bounded pause for the installed pre-dispatch revocation check.
/// It controls when an already-created task resumes, never its route or payload.
enum BrowserUploadDispatchTestBarrier {
    static let environmentKey = "SOLSTONE_BROWSER_UPLOAD_TEST_BARRIER"

    static func resume(
        _ task: URLSessionUploadTask,
        lease: BrowserUploadLease,
        directory: String? = ProcessInfo.processInfo.environment[environmentKey]
    ) {
        guard let directory else { task.resume(); return }
        let root = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { task.cancel(); task.resume(); return }
        defer { close(root) }
        var info = stat()
        guard fstat(root, &info) == 0, info.st_uid == getuid(),
              info.st_mode & 0o777 == 0o700 else { task.cancel(); task.resume(); return }
        let control = openat(root, "release", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard control >= 0 else { task.cancel(); task.resume(); return }
        guard fstat(control, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFIFO,
              info.st_mode & 0o777 == 0o600 else {
            close(control); task.cancel(); task.resume(); return
        }
        let receipt = openat(root, "created.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard receipt >= 0 else {
            let alreadyClaimed = errno == EEXIST
            close(control)
            if !alreadyClaimed { task.cancel() }
            task.resume()
            return
        }
        let bytes = try? JSONSerialization.data(withJSONObject: [
            "pid": getpid(), "task_id": task.taskIdentifier,
            "task_state": task.state.rawValue, "period_id": lease.periodId,
            "lease_valid_at_creation": lease.isValid(), "maximum_wait_ms": 300_000
        ])
        let written = bytes.map { data in
            data.withUnsafeBytes { pointer in
                write(receipt, pointer.baseAddress, pointer.count) == pointer.count
            }
        } ?? false
        let durable = written && fsync(receipt) == 0
        close(receipt)
        guard durable else { close(control); task.cancel(); task.resume(); return }
        DispatchQueue.global(qos: .utility).async {
            defer { close(control) }
            var descriptor = pollfd(fd: control, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 300_000)
            var byte: UInt8 = 0
            let released = ready == 1 && descriptor.revents & Int16(POLLIN) != 0
                && read(control, &byte, 1) == 1 && byte == 0x52
            if !released || !lease.isValid() { task.cancel() }
            task.resume()
        }
    }
}
#endif
