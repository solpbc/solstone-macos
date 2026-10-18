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

public enum JournalIdentityFailure: Sendable, Equatable {
    case invalidURL
    case unexpectedResponseURL
    case httpStatus(Int)
    case timeout
    case decodeError
    case missingMark
    case invalidMark
    case missingInstanceID
    case instanceMismatch
    case cancelled
    case networkError
}

public enum JournalIdentityResolution: Sendable, Equatable {
    case mark(JournalMark, instanceID: String)
    case uncommitted(instanceID: String?)
    case absent
    case failed(JournalIdentityFailure)
}

public enum JournalIdentityRead: Sendable, Equatable {
    case mark(JournalMark)
    case uncommitted
    case unavailable
}

public nonisolated struct JournalIdentityFetcher: Sendable {
    private let session: URLSession
    private let noRedirectDelegate = NoRedirectURLSessionDelegate()
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

    /// Resolves the identity of the journal at `baseURL`.
    public func resolveIdentity(
        baseURL: String,
        expectedInstanceID: String? = nil,
        timeoutInterval: TimeInterval = 2
    ) async -> JournalIdentityResolution {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlString = "\(trimmedBaseURL)/app/link/api/identity"
        guard let url = URL(string: urlString) else {
            Logger.journalMark.debug("journal-mark identity fetch unavailable: invalid-url")
            return .failed(.invalidURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutInterval
        prepareRequest(&request)

        do {
            let (data, response) = try await session.data(for: request, delegate: noRedirectDelegate)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failed(.networkError)
            }
            guard httpResponse.url == request.url else {
                return .failed(.unexpectedResponseURL)
            }
            guard 200..<300 ~= httpResponse.statusCode else {
                Logger.journalMark.debug("journal-mark identity fetch unavailable: http-status \(httpResponse.statusCode, privacy: .public)")
                return .failed(.httpStatus(httpResponse.statusCode))
            }
            let decoded = try JSONDecoder().decode(JournalIdentityResponse.self, from: data)

            if let expectedInstanceID {
                guard let instanceID = decoded.instanceID, !instanceID.isEmpty else {
                    Logger.journalMark.debug("journal-mark identity fetch unavailable: missing-instance-id")
                    return .failed(.missingInstanceID)
                }
                guard instanceID.caseInsensitiveCompare(expectedInstanceID) == .orderedSame else {
                    Logger.journalMark.debug("journal-mark identity fetch unavailable: another-journal")
                    return .failed(.instanceMismatch)
                }
            }

            guard decoded.committed else {
                Logger.journalMark.debug("journal-mark identity fetch unavailable: uncommitted")
                return .uncommitted(instanceID: decoded.instanceID)
            }

            guard let instanceID = decoded.instanceID, !instanceID.isEmpty else {
                Logger.journalMark.debug("journal-mark identity fetch unavailable: missing-instance-id")
                return .failed(.missingInstanceID)
            }
            guard let mark = decoded.mark else {
                Logger.journalMark.debug("journal-mark identity fetch unavailable: missing-mark")
                return .failed(.missingMark)
            }
            guard let valid = JournalMark.validate(mark) else {
                Logger.journalMark.debug("journal-mark identity fetch unavailable: invalid-mark")
                return .failed(.invalidMark)
            }
            return .mark(valid, instanceID: instanceID)
        } catch is CancellationError {
            Logger.journalMark.debug("journal-mark identity fetch cancelled")
            return .failed(.cancelled)
        } catch let error as URLError {
            if error.code == .cancelled {
                Logger.journalMark.debug("journal-mark identity fetch cancelled")
                return .failed(.cancelled)
            }
            if error.code == .timedOut {
                Logger.journalMark.debug("journal-mark identity fetch timed out")
                return .failed(.timeout)
            }
            if isAbsentURLError(error) {
                Logger.journalMark.debug("journal-mark identity fetch absent: \(error.code.rawValue, privacy: .public)")
                return .absent
            }
            Logger.journalMark.debug("journal-mark identity fetch unavailable: url-error \(error.code.rawValue, privacy: .public)")
            return .failed(.networkError)
        } catch is DecodingError {
            Logger.journalMark.debug("journal-mark identity fetch unavailable: decode-error")
            return .failed(.decodeError)
        } catch {
            if isAbsentError(error) {
                Logger.journalMark.debug("journal-mark identity fetch absent: \(String(describing: error), privacy: .public)")
                return .absent
            }
            Logger.journalMark.debug("journal-mark identity fetch unavailable: error \(String(describing: error), privacy: .public)")
            return .failed(.networkError)
        }
    }

    private func isAbsentURLError(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost:
            return true
        default:
            break
        }
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            if underlying.domain == NSPOSIXErrorDomain && (underlying.code == Int(ECONNREFUSED) || underlying.code == Int(EHOSTUNREACH) || underlying.code == Int(ENETUNREACH)) {
                return true
            }
        }
        return false
    }

    private func isAbsentError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(ECONNREFUSED) || ns.code == Int(EHOSTUNREACH) || ns.code == Int(ENETUNREACH)) {
            return true
        }
        return false
    }

    /// Returns the identity read of the journal at `baseURL`. With `expectedInstanceID`, only that
    /// journal's mark counts: right after a re-pair the previous tunnel can still answer for a
    /// moment, and showing its mark would ask the owner to confirm the wrong journal.
    public func fetch(baseURL: String, expectedInstanceID: String? = nil) async -> JournalIdentityRead {
        let resolution = await resolveIdentity(baseURL: baseURL, expectedInstanceID: expectedInstanceID)
        switch resolution {
        case .mark(let mark, _):
            return .mark(mark)
        case .uncommitted:
            return .uncommitted
        case .absent, .failed:
            return .unavailable
        }
    }
}
