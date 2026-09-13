// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import OSLog

internal struct HostLocalLogExportSource: LogExportEntrySourcing {
    func fetch(
        windowStart: Date,
        windowEnd: Date,
        subsystems: [String]
    ) async -> LogExportFetch {
        let store: OSLogStore
        do {
            store = try OSLogStore.local()
        } catch {
            return .failed(
                reason: error.localizedDescription,
                storeScope: LogExportBounds.storeScopeHostLocal
            )
        }

        let reachedWindowStart = reachedWindowStart(store: store, windowStart: windowStart)
        var results: [String: LogExportSubsystemRead] = [:]
        for name in subsystems {
            if Task.isCancelled {
                break
            }
            results[name] = readSubsystem(
                store: store,
                name: name,
                windowStart: windowStart,
                windowEnd: windowEnd
            )
        }
        return .fetched(
            LogExportFetchSuccess(
                storeScope: LogExportBounds.storeScopeHostLocal,
                reachedWindowStart: reachedWindowStart,
                subsystems: results
            )
        )
    }

    private func reachedWindowStart(store: OSLogStore, windowStart: Date) -> Bool {
        do {
            let position = store.position(date: .distantPast)
            let sequence = try store.getEntries(at: position)
            for entry in sequence {
                return entry.date <= windowStart
            }
            return false
        } catch {
            return false
        }
    }

    private func readSubsystem(
        store: OSLogStore,
        name: String,
        windowStart: Date,
        windowEnd: Date
    ) -> LogExportSubsystemRead {
        do {
            let position = store.position(date: windowStart)
            let predicate = NSPredicate(format: "subsystem == %@", name)
            let sequence = try store.getEntries(at: position, matching: predicate)
            var entries: [LogExportEntry] = []
            for item in sequence {
                if Task.isCancelled {
                    break
                }
                guard let log = item as? OSLogEntryLog else { continue }
                if log.date > windowEnd { break }
                entries.append(
                    LogExportEntry(
                        date: log.date,
                        subsystem: log.subsystem,
                        category: log.category,
                        level: logExportLevelName(log.level),
                        process: log.process,
                        message: log.composedMessage
                    )
                )
            }
            return .entries(entries)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }
}

private func logExportLevelName(_ level: OSLogEntryLog.Level) -> String {
    switch level {
    case .undefined:
        return "undefined"
    case .debug:
        return "debug"
    case .info:
        return "info"
    case .notice:
        return "notice"
    case .error:
        return "error"
    case .fault:
        return "fault"
    @unknown default:
        return "undefined"
    }
}
