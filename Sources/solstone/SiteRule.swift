// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public enum SiteRule: Sendable {
    public static let SECOND_LEVELS: Set<String> = [
        "co", "com", "org", "net", "ac", "gov", "edu", "ne", "or", "go"
    ]

    /// Ports `excludedHostname` from hosts.js.
    /// Returns canonical stored host, or nil if invalid.
    public static func storedHost(_ raw: String) -> String? {
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty { return nil }

        // Strip leading wildcards like *. or %2a.
        if let regex = try? NSRegularExpression(pattern: #"^(https?:\/\/)?(?:\*|%2a)\."#, options: .caseInsensitive) {
            let range = NSRange(input.startIndex..<input.endIndex, in: input)
            input = regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: "$1")
        }

        if input.isEmpty || input.contains(where: { $0.isWhitespace }) {
            return nil
        }

        let urlString: String
        if let prefixRegex = try? NSRegularExpression(pattern: #"^https?:\/\/"#, options: .caseInsensitive),
           prefixRegex.firstMatch(in: input, options: [], range: NSRange(input.startIndex..<input.endIndex, in: input)) != nil {
            urlString = input
        } else {
            urlString = "https://" + input
        }

        guard let components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.user == nil,
              components.password == nil else {
            return nil
        }

        // Use Foundation URL host or components percent-encoded host for raw host extraction
        guard let rawHost = components.host, !rawHost.isEmpty else {
            return nil
        }

        // Bracketed IPv6 literal check
        let isBracketedIPv6 = rawHost.hasPrefix("[") && rawHost.hasSuffix("]")
        let hostnameToClean: String
        if isBracketedIPv6 {
            hostnameToClean = rawHost
        } else if let url = URL(string: urlString), let uHost = url.host {
            // URL(string:) converts IDNA to ASCII punycode (e.g. bücher.de -> xn--bcher-kva.de)
            hostnameToClean = uHost
        } else {
            hostnameToClean = rawHost
        }

        let host = siteHostname(hostnameToClean)

        if let ipv6Regex = try? NSRegularExpression(pattern: #"^\[[0-9a-f:.]+\]$"#, options: .caseInsensitive),
           ipv6Regex.firstMatch(in: host, options: [], range: NSRange(host.startIndex..<host.endIndex, in: host)) != nil {
            return host.lowercased()
        }

        // Browsers open hosts with an underscore, so one can be left out.
        let underscoreSanitized = host.replacingOccurrences(of: "_", with: "-")
        return isPlainHostname(underscoreSanitized) ? host : nil
    }

    /// Ports `siteHostname` from hosts.js.
    public static func siteHostname(_ hostname: String) -> String {
        var host = hostname.lowercased()
        if host.hasPrefix("*.") {
            host.removeFirst(2)
        }
        while host.hasPrefix(".") {
            host.removeFirst()
        }
        while host.hasSuffix(".") {
            host.removeLast()
        }

        if host.hasPrefix("www.") {
            let candidate = String(host.dropFirst(4))
            if registrableLooking(candidate) {
                return candidate
            }
        }
        return host
    }

    /// Ports `registrableLooking` from hosts.js.
    public static func registrableLooking(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 2 {
            return labels.allSatisfy { !$0.isEmpty }
        }
        if labels.count == 3 && labels.allSatisfy({ !$0.isEmpty }) && labels[2].count == 2 && SECOND_LEVELS.contains(String(labels[1])) {
            return true
        }
        return false
    }

    /// Ports `isPlainHostname` from hosts.js.
    public static func isPlainHostname(_ hostname: String) -> Bool {
        if isDottedIPv4(hostname) { return true }
        let pattern = #"^[a-z0-9-]+(?:\.[a-z0-9-]+)*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return false }
        return regex.firstMatch(in: hostname, options: [], range: NSRange(hostname.startIndex..<hostname.endIndex, in: hostname)) != nil
    }

    /// Ports `isLocalHostname` from hosts.js.
    public static func isLocalHostname(_ hostname: String) -> Bool {
        let host = hostname.lowercased()
        return host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || isDottedIPv4(host)
    }

    private static func isDottedIPv4(_ host: String) -> Bool {
        let pattern = #"^(?:\d{1,3}\.){3}\d{1,3}$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        guard regex.firstMatch(in: host, options: [], range: NSRange(host.startIndex..<host.endIndex, in: host)) != nil else {
            return false
        }
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return false }
        for part in parts {
            guard let n = Int(part), n >= 0, n <= 255 else { return false }
        }
        return true
    }

    /// Ports `coversSubdomains` from hosts.js.
    public static func coversSubdomains(_ hostname: String) -> Bool {
        let host = hostname.lowercased()
        return host.contains(".") && !isLocalHostname(host) && isPlainHostname(host.replacingOccurrences(of: "_", with: "-"))
    }

    /// Ports `hostCovers` from hosts.js.
    public static func covers(siteHost: String, host: String) -> Bool {
        let site = siteHost.lowercased()
        let h = host.lowercased()
        if site.isEmpty || h.isEmpty { return false }
        return h == site || (coversSubdomains(site) && h.hasSuffix(".\(site)"))
    }

    /// Read-side normalizer.
    /// Unwraps one blob: or view-source: wrapper when inner text is http: or https:.
    /// Lowercases, drops port, drops one trailing dot, IDNA to ASCII, brackets IPv6.
    /// Does not strip www.
    public static func normalizeReadHost(_ input: String) -> String? {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return nil }

        // Unwrap one blob: or view-source: wrapper if inner URL is http: or https:
        if raw.hasPrefix("blob:") {
            let inner = String(raw.dropFirst(5))
            if inner.hasPrefix("http://") || inner.hasPrefix("https://") {
                raw = inner
            } else {
                return nil
            }
        } else if raw.hasPrefix("view-source:") {
            let inner = String(raw.dropFirst(12))
            if inner.hasPrefix("http://") || inner.hasPrefix("https://") {
                raw = inner
            } else {
                return nil
            }
        }

        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        guard let rawHost = components.host, !rawHost.isEmpty else {
            return nil
        }

        // Bracket IPv6 host if needed
        var host: String
        if rawHost.contains(":") && !rawHost.hasPrefix("[") {
            host = "[\(rawHost)]"
        } else if let url = URL(string: raw), let uHost = url.host {
            // URL(string:) converts IDNA to ASCII punycode (e.g. bücher.de -> xn--bcher-kva.de)
            if uHost.contains(":") && !uHost.hasPrefix("[") {
                host = "[\(uHost)]"
            } else {
                host = uHost
            }
        } else {
            host = rawHost
        }

        host = host.lowercased()
        if host.hasSuffix(".") {
            host.removeLast()
        }

        return host.isEmpty ? nil : host
    }
}
