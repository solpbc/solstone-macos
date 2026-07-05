// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

struct JournalConfig: Codable, Equatable, Sendable {
    var journal: JournalConfigSection
}

struct JournalConfigSection: Codable, Equatable, Sendable {
    var name: String
}

struct JournalConfigUpdateRequest: Encodable, Sendable {
    var section = "journal"
    var data: JournalConfigSection
}

struct JournalConfigUpdateResponse: Decodable, Equatable, Sendable {
    var success: Bool
    var config: JournalConfig
}

enum JournalConfigClientError: Error, Equatable {
    case invalidURL
    case invalidResponse
    case serverError(Int)
}

struct JournalConfigClient: Sendable {
    private let baseURL: String
    private let session: URLSession

    init(
        baseURL: String = "http://127.0.0.1:5015",
        sessionConfiguration: URLSessionConfiguration? = nil
    ) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let config = sessionConfiguration ?? .default
        self.session = URLSession(configuration: config)
    }

    func fetchConfig() async throws -> JournalConfig {
        let request = try buildFetchRequest()
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(JournalConfig.self, from: data)
    }

    func updateJournalName(_ name: String) async throws -> JournalConfig {
        let request = try buildUpdateNameRequest(name)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        let decoded = try JSONDecoder().decode(JournalConfigUpdateResponse.self, from: data)
        guard decoded.success else { throw JournalConfigClientError.invalidResponse }
        return decoded.config
    }

    func buildFetchRequest() throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)/app/settings/api/config") else {
            throw JournalConfigClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 5
        return request
    }

    func buildUpdateNameRequest(_ name: String) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)/app/settings/api/config") else {
            throw JournalConfigClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 5
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(JournalConfigUpdateRequest(
            data: JournalConfigSection(name: name)
        ))
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw JournalConfigClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw JournalConfigClientError.serverError(http.statusCode)
        }
    }
}
