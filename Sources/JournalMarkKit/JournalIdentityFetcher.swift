// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SolstoneCore

private nonisolated struct JournalIdentityResponse: Decodable {
    let committed: Bool
    let instanceID: String?
    let mark: JournalMark?

    enum CodingKeys: String, CodingKey {
        case committed
        case instanceID = "instance_id"
        case mark
    }
}

public nonisolated struct JournalIdentityFetcher: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(baseURL: String) async -> JournalMark? {
        let baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlString = "\(baseURL)/app/link/api/identity"
        guard let url = URL(string: urlString) else {
            Logger.journalMark.debug("journal-mark identity fetch unavailable: invalid-url")
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                Logger.journalMark.debug("journal-mark identity fetch unavailable: http-status \(status, privacy: .public)")
                return nil
            }
            let decoded = try JSONDecoder().decode(JournalIdentityResponse.self, from: data)
            guard decoded.committed else {
                Logger.journalMark.debug("journal-mark identity fetch unavailable: uncommitted")
                return nil
            }
            guard let mark = decoded.mark else {
                Logger.journalMark.debug("journal-mark identity fetch unavailable: missing-mark")
                return nil
            }
            guard let valid = JournalMark.validate(mark) else {
                Logger.journalMark.debug("journal-mark identity fetch unavailable: invalid-mark")
                return nil
            }
            return valid
        } catch is CancellationError {
            Logger.journalMark.debug("journal-mark identity fetch cancelled")
            return nil
        } catch let error as DecodingError {
            Logger.journalMark.debug("journal-mark identity fetch unavailable: decode-error \(String(describing: error), privacy: .public)")
            return nil
        } catch {
            Logger.journalMark.debug("journal-mark identity fetch unavailable: error \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
