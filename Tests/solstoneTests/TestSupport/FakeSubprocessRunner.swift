import Foundation
@testable import solstone

struct SubprocessInvocation: Sendable, Equatable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]?
    let timeout: Duration?

    init(executable: URL, arguments: [String], environment: [String: String]? = nil, timeout: Duration? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
    }
}

final class FakeSubprocessRunner: SubprocessRunning, @unchecked Sendable {
    struct Response: Sendable {
        var stdout: Data = Data()
        var stderr: Data = Data()
        var exitCode: Int32 = 0
        var delay: Duration = .zero
        var throwMessage: String?
        var sideEffect: (@Sendable () -> Void)?

        static func success(
            stdout: Data = Data(),
            stderr: Data = Data(),
            exitCode: Int32 = 0,
            delay: Duration = .zero,
            sideEffect: (@Sendable () -> Void)? = nil
        ) -> Response {
            Response(stdout: stdout, stderr: stderr, exitCode: exitCode, delay: delay, sideEffect: sideEffect)
        }

        static func failure(_ message: String, sideEffect: (@Sendable () -> Void)? = nil) -> Response {
            Response(throwMessage: message, sideEffect: sideEffect)
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
        timeout: Duration?,
        stdoutHandler: @escaping @Sendable (Data) -> Void,
        stderrHandler: @escaping @Sendable (Data) -> Void
    ) async throws -> SubprocessResult {
        let response = nextResponse(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
        if let timeout, response.delay >= timeout {
            try? await Task.sleep(for: timeout)
            return SubprocessResult(exitCode: 137, terminationReason: .uncaughtSignal)
        }
        if response.delay != .zero {
            try? await Task.sleep(for: response.delay)
        }
        response.sideEffect?()
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

    private func nextResponse(executable: URL, arguments: [String], environment: [String: String]?, timeout: Duration?) -> Response {
        lock.lock()
        defer { lock.unlock() }

        recordedInvocations.append(SubprocessInvocation(executable: executable, arguments: arguments, environment: environment, timeout: timeout))
        let key = responseKey(for: executable, arguments: arguments)
        guard var values = responses[key], !values.isEmpty else {
            return .success()
        }
        let response = values.removeFirst()
        responses[key] = values
        return response
    }

    private func responseKey(for executable: URL, arguments: [String]) -> String {
        let executableName = executable.lastPathComponent
        if executableName == "codesign" { return "codesign" }
        if executableName == "ps" { return "ps" }
        if executableName == "lsof" { return "lsof" }
        guard let first = arguments.first else { return "" }
        if first == "tool" { return "tool" }
        if first == "setup" { return "setup" }
        if first == "service" { return "service" }
        if first == "config" { return "config" }
        if first == "observer" { return "observer" }
        if first == "up" { return "up" }
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
