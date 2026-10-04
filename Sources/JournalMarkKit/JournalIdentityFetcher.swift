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

public enum JournalIdentityRead: Sendable, Equatable {
    case mark(JournalMark)
    case uncommitted
    case unavailable
}

public nonisolated struct JournalIdentityFetcher: Sendable {
    private let session: URLSession
    private let prepareRequest: @Sendable (inout URLRequest) -> Void

    /// `prepareRequest` runs on every request before it is sent; the app uses it
    /// to attach the loopback capability the tunnel's local proxy requires.
    public init(
        session: URLSession = .shared,
        prepareRequest: @escaping @Sendable (inout URLRequest) -> Void = { _ in }
    ) {
        self.session = session
        self.prepareRequest = prepareRequest
    }

    /// Returns the identity read of the journal at `baseURL`. With `expectedInstanceID`, only that
    /// journal's mark counts: right after a re-pair the previous tunnel can still answer for a
    /// moment, and showing its mark would ask the owner to confirm the wrong journal.
    public func fetch(baseURL: String, expectedInstanceID: String? = nil) async -> JournalIdentityRead {
        let baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlString = "\(baseURL)/app/link/api/identity"
        guard let url = URL(string: urlString) else {
            Logger.journalMark.debug("journal-mark identity fetch unavailable: invalid-url")
            return .unavailable
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        prepareRequest(&request)

        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                Logger.journalMark.debug("journal-mark identity fetch unavailable: http-status \(status, privacy: .public)")
                return .unavailable
            }
            let decoded = try JSONDecoder().decode(JournalIdentityResponse.self, from: data)
            if let expectedInstanceID {
                guard let instanceID = decoded.instanceID, instanceID.caseInsensitiveCompare(expectedInstanceID) == .orderedSame else {
                    Logger.journalMark.debug("journal-mark identity fetch unavailable: another-journal")
                    return .unavailable
                }
            }
            guard decoded.committed else {
                Logger.journalMark.debug("journal-mark identity fetch unavailable: uncommitted")
                return .uncommitted
            }
            guard let mark = decoded.mark else {
                Logger.journalMark.debug("journal-mark identity fetch unavailable: missing-mark")
                return .unavailable
            }
            guard let valid = JournalMark.validate(mark) else {
                Logger.journalMark.debug("journal-mark identity fetch unavailable: invalid-mark")
                return .unavailable
            }
            return .mark(valid)
        } catch is CancellationError {
            Logger.journalMark.debug("journal-mark identity fetch cancelled")
            return .unavailable
        } catch let error as DecodingError {
            Logger.journalMark.debug("journal-mark identity fetch unavailable: decode-error \(String(describing: error), privacy: .public)")
            return .unavailable
        } catch {
            Logger.journalMark.debug("journal-mark identity fetch unavailable: error \(String(describing: error), privacy: .public)")
            return .unavailable
        }
    }
}
