// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Darwin
import JournalRuntime
import Testing
@testable import journal

@MainActor
@Suite("JournalAppReceipts")
struct JournalAppReceiptTests {
    @Test func objectiveCDelegateInitializerIsImplemented() {
        let type: NSObject.Type = JournalAppDelegate.self
        let delegate = type.init()
        #expect(delegate is JournalAppDelegate)
    }

    @Test func outerEntryPersistsSynchronouslyWhenNoAppModelExists() throws {
        let baseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".journal-app-receipts-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let appBundle = try makeApplicationBundle(at: baseURL)
        var capturedContext: JournalRuntimeEntryReceiptContext?
        JournalAppModel.shared = nil
        defer { JournalAppModel.shared = nil }
        let delegate = JournalAppDelegate(
            receiptContextFactory: {
                let context = JournalRuntimeEntryReceiptLaunch.begin(
                    bundle: appBundle,
                    applicationSupportBaseURL: baseURL
                )
                capturedContext = context
                return context
            },
            modelLauncher: { _ in }
        )

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let context = try #require(capturedContext)
        let sink = FileJournalRuntimeEntryReceiptSink(applicationSupportBaseURL: baseURL)
        #expect(sink.validate(attemptID: context.attemptID).isValidClosed)
    }

    @Test func receiptContextFactoryRunsBeforeModelLaunch() {
        let context = makeJournalTestReceiptContext()
        var events: [String] = []
        let delegate = JournalAppDelegate(
            receiptContextFactory: {
                events.append("receipt")
                return context
            },
            modelLauncher: { _ in
                events.append("model")
            }
        )

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        #expect(events == ["receipt", "model"])
    }

    @Test func independentDelegateLaunchesHaveIndependentAttemptChains() {
        let firstSink = RecordingJournalRuntimeEntryReceiptSink()
        let secondSink = RecordingJournalRuntimeEntryReceiptSink()
        let first = makeJournalTestReceiptContext(sink: firstSink)
        let second = makeJournalTestReceiptContext(sink: secondSink)
        let notification = Notification(name: NSApplication.didFinishLaunchingNotification)

        JournalAppDelegate(receiptContextFactory: { first }, modelLauncher: { _ in })
            .applicationDidFinishLaunching(notification)
        JournalAppDelegate(receiptContextFactory: { second }, modelLauncher: { _ in })
            .applicationDidFinishLaunching(notification)

        #expect(first.attemptID != second.attemptID)
        #expect(firstSink.drafts().count == 1)
        #expect(secondSink.drafts().count == 1)
    }

    @Test func failingOuterSinkDoesNotBlockModelLaunch() {
        let sink = RecordingJournalRuntimeEntryReceiptSink()
        sink.failure = .lockTimeout
        let attemptID = JournalRuntimeEntryAttemptID()
        let identity = JournalRuntimeEntryReceiptAppIdentity(
            appPID: 99,
            bundleIdentifier: "app.solstone.journal",
            bundleShortVersion: "2.0.0",
            bundleVersion: "25",
            locationClass: .standard,
            appKernelStartTimeMicroseconds: 1_000_000
        )
        let context = JournalRuntimeEntryReceiptContext(
            attemptID: attemptID,
            sink: sink,
            appIdentity: identity,
            candidateProvenance: nil
        )
        var modelLaunches = 0
        let delegate = JournalAppDelegate(
            receiptContextFactory: {
                _ = sink.appendSynchronously(.outerEntry(.init(
                    attemptID: attemptID,
                    observedAtUnixMilliseconds: 1,
                    appIdentity: identity
                )))
                return context
            },
            modelLauncher: { _ in modelLaunches += 1 }
        )

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        #expect(sink.drafts().isEmpty)
        #expect(modelLaunches == 1)
    }

    @Test func beginCapturesInjectedBoundProcessEvidence() throws {
        let baseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".journal-app-receipt-evidence-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let appBundle = try makeApplicationBundle(at: baseURL)
        let sink = RecordingJournalRuntimeEntryReceiptSink()
        let expectedPID = getpid()

        let context = JournalRuntimeEntryReceiptLaunch.begin(
            bundle: appBundle,
            sink: sink,
            processEvidenceLookup: { pid in
                guard pid == expectedPID else { return nil }
                return JournalProcessEvidence(
                    pid: pid,
                    ppid: 1,
                    uid: getuid(),
                    username: "test",
                    kernelStartTime: 1_234.567_891
                )
            }
        )

        let appIdentity = try #require(context.appIdentity)
        #expect(appIdentity.appPID == expectedPID)
        #expect(appIdentity.appKernelStartTimeMicroseconds == 1_234_567_891)
        guard case .outerEntry(let outer) = try #require(sink.drafts().first) else {
            Issue.record("expected outer entry")
            return
        }
        #expect(outer.appIdentity.appKernelStartTimeMicroseconds == 1_234_567_891)
    }

    @Test func mismatchedProcessEvidenceFailsOpenWithoutBlockingModelLaunch() throws {
        let baseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".journal-app-receipt-mismatch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let appBundle = try makeApplicationBundle(at: baseURL)
        let sink = RecordingJournalRuntimeEntryReceiptSink()
        let context = JournalRuntimeEntryReceiptLaunch.begin(
            bundle: appBundle,
            sink: sink,
            processEvidenceLookup: { pid in
                JournalProcessEvidence(
                    pid: pid + 1,
                    ppid: 1,
                    uid: getuid(),
                    username: "test",
                    kernelStartTime: 1_000
                )
            }
        )
        var modelLaunches = 0
        let delegate = JournalAppDelegate(
            receiptContextFactory: { context },
            modelLauncher: { _ in modelLaunches += 1 }
        )

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        #expect(context.appIdentity == nil)
        #expect(sink.drafts().isEmpty)
        #expect(modelLaunches == 1)
    }
}

private extension JournalRuntimeEntryReceiptChainValidationResult {
    var isValidClosed: Bool {
        if case .validClosed = self { return true }
        return false
    }
}

private func makeApplicationBundle(at baseURL: URL) throws -> Bundle {
    let bundleURL = baseURL.appendingPathComponent("JournalAppIdentity.bundle", isDirectory: true)
    let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
    let info: [String: String] = [
        "CFBundleIdentifier": "app.solstone.journal",
        "CFBundleShortVersionString": "2.0.0",
        "CFBundleVersion": "25"
    ]
    let data = try PropertyListSerialization.data(
        fromPropertyList: info,
        format: .xml,
        options: 0
    )
    try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
    return try #require(Bundle(url: bundleURL))
}
