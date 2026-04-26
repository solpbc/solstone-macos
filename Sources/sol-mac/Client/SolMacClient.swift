import Foundation
import Network
import SolstoneCore

public enum SolMacClientError: Error {
    case appNotRunning
    case timeout
    case decodeFailed(underlying: Error)
}

public enum SolMacClient {
    public static func send(
        _ request: IPCRequest,
        socketURL: URL = SolMacIPCConstants.socketURL,
        connectTimeout: Duration = .seconds(1),
        requestTimeout: Duration = .seconds(5)
    ) async throws -> IPCResponse {
        guard FileManager.default.fileExists(atPath: socketURL.path) else {
            throw SolMacClientError.appNotRunning
        }

        let connection = NWConnection(to: .unix(path: socketURL.path), using: .tcp)
        let io = ConnectionIO(connection: connection)

        do {
            try await withTimeout(connectTimeout) {
                try await io.start()
            }

            let responseData = try await withTimeout(requestTimeout) {
                var data = try IPCWire.encoder.encode(request)
                data.append(0x0A)
                try await io.send(data)
                return try await io.receiveLine()
            }

            do {
                return try IPCWire.decoder.decode(IPCResponse.self, from: responseData)
            } catch {
                throw SolMacClientError.decodeFailed(underlying: error)
            }
        } catch let error as SolMacClientError {
            io.cancel()
            throw error
        } catch {
            io.cancel()
            throw map(error)
        }
    }

    private static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let resumeState = ResumeState()

            let operationTask = Task {
                do {
                    let value = try await operation()
                    if resumeState.markResumed() {
                        continuation.resume(returning: value)
                    }
                } catch {
                    if resumeState.markResumed() {
                        continuation.resume(throwing: error)
                    }
                }
            }

            Task {
                try? await Task.sleep(for: timeout)
                if resumeState.markResumed() {
                    operationTask.cancel()
                    continuation.resume(throwing: SolMacClientError.timeout)
                }
            }
        }
    }

    private static func map(_ error: Error) -> SolMacClientError {
        if let error = error as? NWError {
            switch error {
            case .posix(let posixError) where posixError == .ECONNREFUSED || posixError == .ENOENT:
                return .appNotRunning
            default:
                return .timeout
            }
        }

        if let error = error as? ConnectionIO.ConnectionError {
            switch error {
            case .cancelled, .eof:
                return .appNotRunning
            }
        }

        return .timeout
    }
}

private final class ConnectionIO: @unchecked Sendable {
    enum ConnectionError: Error {
        case cancelled
        case eof
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "app.solstone.observer.cli")

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() async throws {
        let resumeState = ResumeState()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                guard resumeState.markResumed() else { return }
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                case .cancelled:
                    continuation.resume(throwing: ConnectionError.cancelled)
                default:
                    resumeState.setResumed(false)
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receiveLine() async throws -> Data {
        var buffer = Data()

        while true {
            let (data, isComplete) = try await receiveChunk()
            if let data {
                buffer.append(data)
            }

            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                return buffer[..<newlineIndex]
            }

            if isComplete {
                throw ConnectionError.eof
            }
        }
    }

    func cancel() {
        connection.cancel()
    }

    private func receiveChunk() async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data?, Bool), Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, isComplete))
                }
            }
        }
    }
}

private final class ResumeState: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func markResumed() -> Bool {
        lock.withLock {
            guard !resumed else { return false }
            resumed = true
            return true
        }
    }

    func setResumed(_ resumed: Bool) {
        lock.withLock {
            self.resumed = resumed
        }
    }
}
