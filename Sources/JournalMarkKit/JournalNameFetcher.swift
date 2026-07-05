// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SolstoneCore

private struct JournalNameConfigResponse: Decodable {
    let journal: JournalNameConfigSection?
}

private struct JournalNameConfigSection: Decodable {
    let name: String?
}

public struct JournalNameFetcher: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(baseURL: String) async -> String? {
        let baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlString = "\(baseURL)/app/settings/api/config"
        guard let url = URL(string: urlString) else {
            Logger.setup.debug("journal-name fetch unavailable: invalid-url")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 5

        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                Logger.setup.debug("journal-name fetch unavailable: http-status \(status, privacy: .public)")
                return nil
            }

            let decoded = try JSONDecoder().decode(JournalNameConfigResponse.self, from: data)
            guard let rawName = decoded.journal?.name else {
                Logger.setup.debug("journal-name fetch unavailable: missing-name")
                return nil
            }

            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                Logger.setup.debug("journal-name fetch unavailable: empty-name")
                return nil
            }

            return name
        } catch is CancellationError {
            Logger.setup.debug("journal-name fetch cancelled")
            return nil
        } catch let error as DecodingError {
            Logger.setup.debug("journal-name fetch unavailable: decode-error \(String(describing: error), privacy: .public)")
            return nil
        } catch {
            Logger.setup.debug("journal-name fetch unavailable: error \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
