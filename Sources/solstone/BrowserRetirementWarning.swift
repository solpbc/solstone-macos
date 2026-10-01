// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

/// A warning that has appeared stays until the owner answers its prompt.
struct BrowserRetirementWarning: Equatable {
    private(set) var isShown = false

    mutating func observe(isPromptOpen: Bool, hasPendingMaterial: Bool?) {
        if !isPromptOpen {
            isShown = false
        } else if hasPendingMaterial == true {
            isShown = true
        }
    }
}

#endif
