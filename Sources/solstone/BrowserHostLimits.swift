// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

extension BrowserHostLimits {
    public init(projection: BrowserContractProjection) {
        self.init(
            extensionToHost: projection.caps.extensionToHost,
            hostToExtension: projection.caps.hostToExtension,
            control: projection.caps.control,
            partialFrameMs: projection.policy.partialFrameMs,
            handshakeMs: projection.policy.handshakeMs
        )
    }
}

#endif
