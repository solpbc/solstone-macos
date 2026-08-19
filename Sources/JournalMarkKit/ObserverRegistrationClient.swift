// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SolstoneCore

public struct ObserverRegistrationDescriptor: Encodable, Sendable, Equatable {
    public let platform: String
    public let hostname: String
    public let streamType: String
    public let version: String

    public init(platform: String, hostname: String, streamType: String, version: String) {
        self.platform = platform
        self.hostname = hostname
        self.streamType = streamType
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case platform
        case hostname
        case streamType = "stream_type"
        case version
    }
}

private struct ObserverRegistrationResponse: Decodable {
    let key: String
    let name: String
}

public struct ObserverRegistration: Sendable, Equatable {
    public let key: String
    public let streamName: String

    public init(key: String, streamName: String) {
        self.key = key
        self.streamName = streamName
    }
}

public enum ObserverRegistrationFailureKind: Sendable, Equatable {
    case invalidURL
    case requestEncoding
    case transport
    case invalidResponse
    case httpStatus(Int)
    case decode
    case emptyKey
    case emptyName
}

public struct ObserverRegistrationFailure: Error, Sendable, Equatable {
    public let kind: ObserverRegistrationFailureKind
    public let detail: String

    public init(kind: ObserverRegistrationFailureKind, detail: String = "") {
        self.kind = kind
        self.detail = detail
    }
}

public struct ObserverRegistrationClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func register(
        baseURL: String,
        descriptor: ObserverRegistrationDescriptor
    ) async -> Result<ObserverRegistration, ObserverRegistrationFailure> {
        let baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = "\(baseURL)/app/devices/register"
        guard let url = URL(string: endpoint) else {
            return fail(.invalidURL, "observer registration unavailable: invalid-url \(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 5

        do {
            request.httpBody = try JSONEncoder().encode(descriptor)
        } catch {
            return fail(.requestEncoding, "observer registration request encode failed: \(error)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            return fail(.transport, "observer registration request cancelled")
        } catch {
            return fail(.transport, "observer registration request failed: \(error)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            return fail(.invalidResponse, "observer registration response was not HTTP")
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            return fail(
                .httpStatus(httpResponse.statusCode),
                "observer registration response status \(httpResponse.statusCode)"
            )
        }

        let decoded: ObserverRegistrationResponse
        do {
            decoded = try JSONDecoder().decode(ObserverRegistrationResponse.self, from: data)
        } catch {
            return fail(.decode, "observer registration response decode failed: \(error)")
        }

        let key = decoded.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return fail(.emptyKey, "observer registration response key was empty")
        }

        let streamName = decoded.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !streamName.isEmpty else {
            return fail(.emptyName, "observer registration response name was empty")
        }

        let message = Self.successLogMessage(hostname: descriptor.hostname, streamName: streamName)
        Logger.setup.notice("\(message, privacy: .public)")
        return .success(ObserverRegistration(key: key, streamName: streamName))
    }

    public static func successLogMessage(hostname: String, streamName: String) -> String {
        "observer registration succeeded hostname=\(hostname) streamName=\(streamName)"
    }

    private func fail(
        _ kind: ObserverRegistrationFailureKind,
        _ detail: String
    ) -> Result<ObserverRegistration, ObserverRegistrationFailure> {
        Logger.setup.debug("\(detail, privacy: .public)")
        return .failure(ObserverRegistrationFailure(kind: kind, detail: detail))
    }
}
