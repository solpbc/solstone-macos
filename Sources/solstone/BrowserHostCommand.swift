// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Darwin
import Foundation

enum BrowserHostCommand {
    enum Command {
        case check(BrowserHostRegistrationMode)
        case repair(BrowserHostRegistrationMode)
    }

    static func command(arguments: [String]) -> Command? {
        guard let first = arguments.dropFirst().first,
              first == "browser-host-check" || first == "browser-host-repair" else { return nil }
        let tail = Array(arguments.dropFirst(2))
        guard tail.count <= 1 else { return nil }
        let mode: BrowserHostRegistrationMode
        if tail.isEmpty { mode = .production }
        else if tail[0] == "--development" { mode = .development }
        else { return nil }
        return first == "browser-host-check" ? .check(mode) : .repair(mode)
    }

    static func run(arguments: [String], output: (String) -> Void = { print($0) }) -> Int? {
        guard let command = command(arguments: arguments) else { return nil }
        let bundleURL = Bundle.main.bundleURL
        guard let contractRoot = BrowserContractProjection.vendorRootURL(bundleURL: bundleURL) else {
            output("unknown contract_unavailable")
            return 1
        }
        let helperURL = helperURL(for: command, bundleURL: bundleURL)
        let registration = BrowserHostRegistration(contractRoot: contractRoot, helperURL: helperURL)
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Solstone/browser-intake", isDirectory: true)
        let fence = BrowserHostEndpointFence(rootURL: root)
        let report: BrowserHostRegistrationReport
        let endpoint: BrowserHostEndpointDisposition
        let checkOnly: Bool
        switch command {
        case .check(let mode):
            endpoint = fence.inspectEndpoint()
            report = registration.check(mode: mode)
            checkOnly = true
        case .repair(let mode):
            endpoint = (try? fence.repairStaleEndpoint()) ?? .refused
            report = registration.repair(mode: mode)
            checkOnly = false
        }
        for brand in BrowserBrand.allCases {
            guard let result = report.outcomes[brand] else {
                output("unknown registration_incomplete")
                continue
            }
            if let path = result.path, let reason = result.reasonCode {
                output("\(path) \(reason)")
            } else if let path = result.path {
                output("\(path) \(result.state.rawValue)")
            } else {
                output("\(result.reasonCode ?? "registration_incomplete")")
            }
        }
        switch endpoint {
        case .absent, .removed:
            break
        case .live:
            output("endpoint_live")
        case .stale:
            output("endpoint_stale")
        case .refused:
            output("endpoint_collision")
        }
        let registrationReady = checkOnly
            ? report.outcomes.values.allSatisfy { $0.state == .ready }
            : report.isComplete
        let endpointReady = endpoint == .absent || endpoint == .removed
        return registrationReady && endpointReady ? 0 : 1
    }

    private static func helperURL(for command: Command, bundleURL: URL) -> URL {
        if case .repair(.development) = command,
           let explicit = ProcessInfo.processInfo.environment["SOLSTONE_BROWSER_HOST_PATH"] {
            return URL(fileURLWithPath: explicit)
        }
        if case .check(.development) = command,
           let explicit = ProcessInfo.processInfo.environment["SOLSTONE_BROWSER_HOST_PATH"] {
            return URL(fileURLWithPath: explicit)
        }
        return bundleURL.appendingPathComponent("Contents/MacOS/solstone-browser-host")
    }
}

#endif
