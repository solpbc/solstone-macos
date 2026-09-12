import Foundation
import JournalRuntime

public struct SubprocessInvocation: Sendable, Equatable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]?
    public let timeout: Duration?

    public init(executable: URL, arguments: [String], environment: [String: String]? = nil, timeout: Duration? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
    }
}

public final class FakeSubprocessRunner: SubprocessRunning, @unchecked Sendable {
    public struct Response: Sendable {
        public var stdout: Data = Data()
        public var stderr: Data = Data()
        public var exitCode: Int32 = 0
        public var delay: Duration = .zero
        public var throwMessage: String?
        public var sideEffect: (@Sendable () -> Void)?

        public static func success(
            stdout: Data = Data(),
            stderr: Data = Data(),
            exitCode: Int32 = 0,
            delay: Duration = .zero,
            sideEffect: (@Sendable () -> Void)? = nil
        ) -> Response {
            Response(stdout: stdout, stderr: stderr, exitCode: exitCode, delay: delay, sideEffect: sideEffect)
        }

        public static func failure(_ message: String, sideEffect: (@Sendable () -> Void)? = nil) -> Response {
            Response(throwMessage: message, sideEffect: sideEffect)
        }
    }

    private let lock = NSLock()
    private var responses: [String: [Response]] = [:]
    private var recordedInvocations: [SubprocessInvocation] = []

    public init() {}

    public var invocations: [SubprocessInvocation] {
        lock.lock()
        defer { lock.unlock() }
        return recordedInvocations
    }

    public func enqueue(_ key: String, _ response: Response) {
        lock.lock()
        responses[key, default: []].append(response)
        lock.unlock()
    }

    public func enqueueLsof(port: Int, _ response: Response) {
        enqueue("lsof:\(port)", response)
    }

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: Duration?,
        stdoutHandler: @escaping @Sendable (Data) -> Void,
        stderrHandler: @escaping @Sendable (Data) -> Void
    ) async throws -> SubprocessResult {
        // sol --version is the materializer's post-rename completeness probe; any other sol call is still a bug.
        if executable.lastPathComponent == "sol", arguments != ["--version"] {
            throw FakeRunError(message: "unexpected sol subprocess invocation")
        }
        if executable.lastPathComponent == "mlx-vlm-server" {
            throw FakeRunError(message: "unexpected mlx-vlm-server subprocess invocation")
        }
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

    public func cancelAll() {
    }

    private func nextResponse(executable: URL, arguments: [String], environment: [String: String]?, timeout: Duration?) -> Response {
        lock.lock()
        defer { lock.unlock() }

        recordedInvocations.append(SubprocessInvocation(executable: executable, arguments: arguments, environment: environment, timeout: timeout))
        let keys = responseKeys(for: executable, arguments: arguments)
        return dequeueResponse(for: keys) ?? .success()
    }

    private func dequeueResponse(for keys: [String]) -> Response? {
        guard let key = keys.first(where: { responses[$0]?.isEmpty == false }),
              var values = responses[key], !values.isEmpty else {
            return nil
        }
        let response = values.removeFirst()
        responses[key] = values
        return response
    }

    private func responseKeys(for executable: URL, arguments: [String]) -> [String] {
        let executableName = executable.lastPathComponent
        if executableName == "codesign" { return ["codesign"] }
        if executableName == "ps" { return ["ps"] }
        if executableName == "lsof" {
            if let port = lsofPort(from: arguments) {
                return ["lsof:\(port)", "lsof"]
            }
            return ["lsof"]
        }
        guard let first = arguments.first else { return [""] }
        if first == "tool" { return ["tool"] }
        if first == "setup" { return ["setup"] }
        if first == "service" { return ["service"] }
        if first == "config" { return ["config"] }
        if first == "up" { return ["up"] }
        if first == "install-models" { return ["install-models"] }
        if first == "health" { return ["health"] }
        if first == "--version" { return ["--version"] }
        return [first]
    }

    private func lsofPort(from arguments: [String]) -> Int? {
        for argument in arguments where argument.hasPrefix("-iTCP:") {
            return Int(argument.dropFirst("-iTCP:".count))
        }
        return nil
    }
}

public extension FakeSubprocessRunner {
    func lsofPorts() -> [Int] {
        invocations.compactMap { invocation in
            invocation.arguments.first { $0.hasPrefix("-iTCP:") }
                .flatMap { Int($0.dropFirst("-iTCP:".count)) }
        }
    }
}

public struct FakeRunError: LocalizedError, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}
