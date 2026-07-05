// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public enum JournalInitClientError: Error, Equatable {
    case invalidURL
    case invalidResponse
    case serverError(Int)
    case invalidOperationForState(detail: String)
    case identityNotLocked(detail: String)
}

public struct JournalInitMarkResponse: Decodable, Sendable, Equatable {
    public let mark: JournalMark
    public let locked: Bool

    public init(mark: JournalMark, locked: Bool) {
        self.mark = mark
        self.locked = locked
    }

    private enum CodingKeys: String, CodingKey {
        case mark
        case locked
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedMark = try container.decode(JournalMark.self, forKey: .mark)
        guard let validMark = JournalMark.validate(decodedMark) else {
            throw JournalInitClientError.invalidResponse
        }
        mark = validMark
        locked = try container.decode(Bool.self, forKey: .locked)
    }
}

public struct JournalInitFinalizeRequest: Encodable, Sendable, Equatable {
    public init() {}
}

public struct JournalInitFinalizeResponse: Decodable, Sendable, Equatable {
    public let success: Bool
    public let redirect: String
    public let warnings: [String]

    public init(success: Bool, redirect: String, warnings: [String]) {
        self.success = success
        self.redirect = redirect
        self.warnings = warnings
    }
}

public enum JournalInitSetupProbe: Sendable, Equatable {
    case complete
    case incomplete
}

public struct JournalInitClient: Sendable {
    private let baseURL: String
    private let session: URLSession
    private let probeSession: URLSession
    private let noRedirectDelegate: NoRedirectURLSessionDelegate

    public init(
        baseURL: String = "http://127.0.0.1:5015",
        sessionConfiguration: URLSessionConfiguration? = nil
    ) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let config = sessionConfiguration ?? .default
        self.session = URLSession(configuration: config)
        let delegate = NoRedirectURLSessionDelegate()
        self.noRedirectDelegate = delegate
        let probeConfig = sessionConfiguration ?? .default
        self.probeSession = URLSession(configuration: probeConfig, delegate: delegate, delegateQueue: nil)
    }

    public func getMark() async throws -> JournalInitMarkResponse {
        try await sendMarkRequest(path: "/init/mark", method: "GET")
    }

    public func regenerateMark() async throws -> JournalInitMarkResponse {
        try await sendMarkRequest(path: "/init/mark/regenerate", method: "POST")
    }

    public func lockMark() async throws -> JournalInitMarkResponse {
        try await sendMarkRequest(path: "/init/mark/lock", method: "POST")
    }

    public func finalize(body: JournalInitFinalizeRequest = JournalInitFinalizeRequest()) async throws -> JournalInitFinalizeResponse {
        var request = try buildRequest(path: "/init/finalize", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(JournalInitFinalizeResponse.self, from: data)
        guard decoded.success else {
            throw JournalInitClientError.invalidResponse
        }
        return decoded
    }

    public func probeSetupComplete() async throws -> JournalInitSetupProbe {
        var request = try buildRequest(path: "/init", method: "GET")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (_, response) = try await probeSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw JournalInitClientError.invalidResponse
        }
        switch http.statusCode {
        case 302:
            return .complete
        case 200:
            return .incomplete
        default:
            throw JournalInitClientError.serverError(http.statusCode)
        }
    }

    func buildRequest(path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw JournalInitClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 5
        return request
    }

    private func sendMarkRequest(path: String, method: String) async throws -> JournalInitMarkResponse {
        let request = try buildRequest(path: path, method: method)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(JournalInitMarkResponse.self, from: data)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw JournalInitClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw mappedError(statusCode: http.statusCode, data: data)
        }
    }

    private func mappedError(statusCode: Int, data: Data) -> JournalInitClientError {
        guard let decoded = try? JSONDecoder().decode(JournalInitErrorResponse.self, from: data) else {
            return .serverError(statusCode)
        }
        let detail = decoded.detail ?? ""
        switch decoded.reasonCode ?? decoded.reason {
        case "invalid_operation_for_state":
            return .invalidOperationForState(detail: detail)
        case "identity_not_locked":
            return .identityNotLocked(detail: detail)
        default:
            return .serverError(statusCode)
        }
    }
}

private struct JournalInitErrorResponse: Decodable {
    let reason: String?
    let reasonCode: String?
    let detail: String?

    enum CodingKeys: String, CodingKey {
        case reason
        case reasonCode = "reason_code"
        case detail
    }
}

private final class NoRedirectURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
