import Foundation
@testable import solstone

struct SubprocessInvocation: Sendable, Equatable {
    let executable: URL
    let arguments: [String]
}

final class FakeSubprocessRunner: SubprocessRunning, @unchecked Sendable {
    struct Response: Sendable {
        var stdout: Data = Data()
        var stderr: Data = Data()
        var exitCode: Int32 = 0
        var delay: Duration = .zero
        var throwMessage: String?

        static func success(
            stdout: Data = Data(),
            stderr: Data = Data(),
            exitCode: Int32 = 0,
            delay: Duration = .zero
        ) -> Response {
            Response(stdout: stdout, stderr: stderr, exitCode: exitCode, delay: delay)
        }

        static func failure(_ message: String) -> Response {
            Response(throwMessage: message)
        }
    }

    private let lock = NSLock()
    private var responses: [String: [Response]] = [:]
    private var recordedInvocations: [SubprocessInvocation] = []

    var invocations: [SubprocessInvocation] {
        lock.lock()
        defer { lock.unlock() }
        return recordedInvocations
    }

    func enqueue(_ key: String, _ response: Response) {
        lock.lock()
        responses[key, default: []].append(response)
        lock.unlock()
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        stdoutHandler: @escaping @Sendable (Data) -> Void,
        stderrHandler: @escaping @Sendable (Data) -> Void
    ) async throws -> SubprocessResult {
        let response = nextResponse(executable: executable, arguments: arguments)
        if response.delay != .zero {
            try? await Task.sleep(for: response.delay)
        }
        if let message = response.throwMessage {
            throw FakeRunError(message: message)
        }
        if !response.stdout.isEmpty {
            stdoutHandler(response.stdout)
        }
        if !response.stderr.isEmpty {
            stderrHandler(response.stderr)
        }
        return SubprocessResult(exitCode: response.exitCode, terminationReason: response.exitCode == 0 ? .exit : .exit)
    }

    func cancelAll() {
    }

    private func nextResponse(executable: URL, arguments: [String]) -> Response {
        lock.lock()
        defer { lock.unlock() }

        recordedInvocations.append(SubprocessInvocation(executable: executable, arguments: arguments))
        let key = responseKey(for: arguments)
        guard var values = responses[key], !values.isEmpty else {
            return .success()
        }
        let response = values.removeFirst()
        responses[key] = values
        return response
    }

    private func responseKey(for arguments: [String]) -> String {
        guard let first = arguments.first else { return "" }
        if first == "tool" { return "tool" }
        if first == "setup" { return "setup" }
        if first == "observer" { return "observer" }
        if first == "install-models" { return "install-models" }
        if first == "health" { return "health" }
        if first == "--version" { return "--version" }
        return first
    }
}

struct FakeRunError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}
