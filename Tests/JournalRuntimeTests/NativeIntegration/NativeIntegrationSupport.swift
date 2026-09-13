// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import JournalRuntimeTestSupport

/// The tier's shared helpers live in `JournalRuntimeTestSupport` so every test target can drive
/// the native runtime the same way; this name keeps the suites here reading naturally.
typealias NativeIntegration = NativeIntegrationHelpers
