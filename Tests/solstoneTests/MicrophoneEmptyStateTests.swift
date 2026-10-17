// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("MicrophoneEmptyState")
struct MicrophoneEmptyStateTests {
    @Test func accessCausesClassifyAsAccess() {
        #expect(classifyMicrophoneEmptyState(authorizationCause: .denied) == .access(.denied))
        #expect(classifyMicrophoneEmptyState(authorizationCause: .restricted) == .access(.restricted))
        #expect(classifyMicrophoneEmptyState(authorizationCause: .notDetermined) == .access(.notDetermined))
    }

    @Test func authorizedClassifiesAsConnect() {
        #expect(classifyMicrophoneEmptyState(authorizationCause: .authorized) == .connect)
    }

    @Test func unknownClassifiesAsCouldNotCheck() {
        #expect(classifyMicrophoneEmptyState(authorizationCause: .unknown) == .couldNotCheck)
    }

    @Test func soundSettingsURLMatchesExtension() {
        #expect(MicrophoneEmptyState.soundSettingsURL.absoluteString == "x-apple.systempreferences:com.apple.Sound-Settings.extension")
    }

    @Test func configuredDisconnectedOrDisabledRowIsNotTheEmptyState() {
        // When priority list is not empty (e.g. contains disconnected or disabled entries),
        // reconcileAndClassifyMicrophoneEmptyState returns nil.
        var syncCalled = false
        let result = reconcileAndClassifyMicrophoneEmptyState(
            isPriorityListEmpty: { false },
            deviceCount: 0,
            authorizationCause: .authorized,
            syncMicrophonePriorityList: { syncCalled = true }
        )
        #expect(result == nil)
        #expect(!syncCalled)
    }

    @Test func devicesWithEmptyPriorityListCallSyncInsteadOfEmptyCopy() {
        var syncCalled = false
        var priorityListEmpty = true

        // 1. If sync populates the priority list, returns nil (not empty).
        let populatedResult = reconcileAndClassifyMicrophoneEmptyState(
            isPriorityListEmpty: { priorityListEmpty },
            deviceCount: 2,
            authorizationCause: .authorized,
            syncMicrophonePriorityList: {
                syncCalled = true
                priorityListEmpty = false
            }
        )
        #expect(syncCalled)
        #expect(populatedResult == nil)

        // 2. If sync does not populate the priority list, returns empty classification.
        syncCalled = false
        priorityListEmpty = true
        let emptyResult = reconcileAndClassifyMicrophoneEmptyState(
            isPriorityListEmpty: { priorityListEmpty },
            deviceCount: 2,
            authorizationCause: .authorized,
            syncMicrophonePriorityList: {
                syncCalled = true
            }
        )
        #expect(syncCalled)
        #expect(emptyResult == .connect)
    }

    @Test func accessibilityIdentifiersAreStaticAndValid() {
        #expect(AXID.Settings.Microphones.empty == "settings.microphones.empty")
        #expect(AXID.Settings.Microphones.emptyPermissions == "settings.microphones.empty.permissions")
        #expect(AXID.Settings.Microphones.emptySound == "settings.microphones.empty.sound")
    }
}
