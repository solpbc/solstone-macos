import Foundation
import Testing
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
        // sol --version is the materializer's post-rename completeness probe; any other sol call is still a bug.
        if executable.lastPathComponent == "sol", arguments != ["--version"] {
            Issue.record("unexpected sol subprocess invocation: \(executable.path) \(arguments.joined(separator: " "))")
            throw FakeRunError(message: "unexpected sol subprocess invocation")
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
        if response.exitCode == 0, arguments.starts(with: ["tool", "install"]) {
            createMaterializedToolBinaries(environment: environment)
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

    private func nextResponse(executable: URL, arguments: [String], environment: [String: String]?, timeout: Duration?) -> Response {
        lock.lock()
        defer { lock.unlock() }

        recordedInvocations.append(SubprocessInvocation(executable: executable, arguments: arguments, environment: environment, timeout: timeout))
        if arguments == ["--version"],
           environment?["UV_TOOL_DIR"] != nil,
           ["journal", "sol"].contains(executable.lastPathComponent) {
            return .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8))
        }
        let key = responseKey(for: executable, arguments: arguments)
        guard var values = responses[key], !values.isEmpty else {
            if arguments == ["-c", "print(1)"] {
                return .success(stdout: Data("1\n".utf8))
            }
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
        if first == "up" { return "up" }
        if first == "install-models" { return "install-models" }
        if first == "health" { return "health" }
        if first == "--version" { return "--version" }
        return first
    }

    private func createMaterializedToolBinaries(environment: [String: String]?) {
        guard let binPath = environment?["UV_TOOL_BIN_DIR"],
              let toolsPath = environment?["UV_TOOL_DIR"] else { return }
        let binURL = URL(fileURLWithPath: binPath, isDirectory: true)
        let toolBinURL = URL(fileURLWithPath: toolsPath, isDirectory: true)
            .appendingPathComponent("solstone/bin", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: toolBinURL, withIntermediateDirectories: true)
            let python = toolBinURL.appendingPathComponent("python")
            let pythonBody = """
            #!/bin/sh
            echo "solstone \(BundleConfig.solstonePinVersion)"
            """
            try Data((pythonBody + "\n").utf8).write(to: python)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

            for name in ["sol", "journal"] {
                let consoleScript = toolBinURL.appendingPathComponent(name)
                let body = """
                #!/bin/sh
                '''exec' \(shellSingleQuoted(python.path)) "$0" "$@"
                ' '''
                # -*- coding: utf-8 -*-
                # fake console script
                """
                try Data((body + "\n").utf8).write(to: consoleScript)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: consoleScript.path)

                let entrypoint = binURL.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: entrypoint.path) {
                    try FileManager.default.removeItem(at: entrypoint)
                }
                try FileManager.default.createSymbolicLink(
                    atPath: entrypoint.path,
                    withDestinationPath: consoleScript.path
                )
            }
        } catch {
            Issue.record("failed to create fake materialized binaries: \(error.localizedDescription)")
        }
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

struct FakeRunError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}
