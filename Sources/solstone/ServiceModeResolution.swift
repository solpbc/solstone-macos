// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SolstoneCore

func resolvedServiceMode(for config: AppConfig) -> ServiceMode {
    config.serviceMode ?? .external
}
