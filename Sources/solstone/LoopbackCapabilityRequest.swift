// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel
import WebKit

nonisolated extension URLRequest {
    /// Proves to the SPL loopback proxy that this request comes from this app.
    ///
    /// The proxy refuses any local connection whose first request lacks the
    /// process's capability, because another process or a web page on this Mac
    /// can reach the same port. Attached only for `127.0.0.1`: the capability is
    /// a secret, and a LAN journal would receive it in cleartext. Cookie handling
    /// is off so the cookie jar can never replace the header.
    mutating func attachLoopbackCapability() {
        guard self.url?.host == "127.0.0.1" else { return }
        self.setValue(LoopbackCapability.process.cookieHeaderValue, forHTTPHeaderField: "Cookie")
        self.httpShouldHandleCookies = false
    }
}

/// Sets the loopback capability cookie in a journal web view's store before a
/// load, so the load and every request its page makes carry it.
@MainActor
func setLoopbackCapabilityCookie(for url: URL, in store: WKHTTPCookieStore) async {
    guard url.host == "127.0.0.1", let cookie = LoopbackCapability.process.httpCookie() else { return }
    await store.setCookie(cookie)
}
