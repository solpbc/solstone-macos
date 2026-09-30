// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Darwin
import Foundation

public enum BrowserHostRegistrationMode: String, Sendable {
    case production
    case development
}

public struct BrowserHostFileInfo: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case regular, directory, socket, symlink, other }
    public let kind: Kind
    public let uid: uid_t
    public let mode: mode_t
    public let device: UInt64
    public let inode: UInt64

    public init(kind: Kind, uid: uid_t, mode: mode_t, device: UInt64 = 0, inode: UInt64 = 0) {
        self.kind = kind
        self.uid = uid
        self.mode = mode
        self.device = device
        self.inode = inode
    }
}

public protocol BrowserHostRegistrationFileSystem: Sendable {
    func info(_ url: URL) -> BrowserHostFileInfo?
    func read(_ url: URL) throws -> Data
    func createDirectory(_ url: URL) throws
    func writeAtomically(_ data: Data, to url: URL) throws
    func resolve(_ url: URL) -> URL
}

public struct LocalBrowserHostRegistrationFileSystem: BrowserHostRegistrationFileSystem {
    public init() {}

    public func info(_ url: URL) -> BrowserHostFileInfo? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return nil }
        let type = value.st_mode & S_IFMT
        let kind: BrowserHostFileInfo.Kind
        switch type {
        case S_IFREG: kind = .regular
        case S_IFDIR: kind = .directory
        case S_IFSOCK: kind = .socket
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        return BrowserHostFileInfo(
            kind: kind,
            uid: value.st_uid,
            mode: value.st_mode,
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino)
        )
    }

    public func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    public func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    public func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    public func resolve(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }
}

public struct BrowserHostRegistrationOutcome: Sendable, Equatable {
    public let brand: BrowserBrand
    public let state: BrowserHostRegistrationState
    public let path: String?
    public let reasonCode: String?

    public init(brand: BrowserBrand, state: BrowserHostRegistrationState, path: String?, reasonCode: String?) {
        self.brand = brand
        self.state = state
        self.path = path
        self.reasonCode = reasonCode
    }
}

public struct BrowserHostRegistrationReport: Sendable, Equatable {
    public let outcomes: [BrowserBrand: BrowserHostRegistrationOutcome]
    public let changedAny: Bool
    public var isComplete: Bool {
        outcomes.count == BrowserBrand.allCases.count && outcomes.values.allSatisfy {
            $0.state == .ready || $0.state == .changed
        }
    }
}

public struct BrowserHostRegistration: Sendable {
    private let contractRoot: URL
    private let home: URL
    private let helperURL: URL
    private let fileSystem: any BrowserHostRegistrationFileSystem
    private let effectiveUID: uid_t

    public init(
        contractRoot: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        helperURL: URL,
        fileSystem: any BrowserHostRegistrationFileSystem = LocalBrowserHostRegistrationFileSystem(),
        effectiveUID: uid_t = geteuid()
    ) {
        self.contractRoot = contractRoot
        self.home = home.standardizedFileURL
        self.helperURL = helperURL
        self.fileSystem = fileSystem
        self.effectiveUID = effectiveUID
    }

    public func check(mode: BrowserHostRegistrationMode = .production) -> BrowserHostRegistrationReport {
        perform(mode: mode, repair: false)
    }

    public func repair(mode: BrowserHostRegistrationMode = .production) -> BrowserHostRegistrationReport {
        perform(mode: mode, repair: true)
    }

    private func perform(mode: BrowserHostRegistrationMode, repair: Bool) -> BrowserHostRegistrationReport {
        if mode == .production, !isBundledProductionHelper() {
            return refusedAll("helper_path_not_bundled")
        }
        guard validateHelperOwnership() else { return refusedAll("unsafe_helper_path") }

        let contract = contractRoot
            .appendingPathComponent("contracts", isDirectory: true)
            .appendingPathComponent("native-browser", isDirectory: true)
        guard let host = hostName(in: contract, mode: mode) else { return refusedAll("invalid_contract") }

        var outcomes: [BrowserBrand: BrowserHostRegistrationOutcome] = [:]
        var changedAny = false
        for brand in BrowserBrand.allCases {
            do {
                let templateURL = contract
                    .appendingPathComponent("registration", isDirectory: true)
                    .appendingPathComponent(mode == .production ? "production" : "dev", isDirectory: true)
                    .appendingPathComponent(brand.rawValue, isDirectory: true)
                    .appendingPathComponent("macos.json")
                let template = try fileSystem.read(templateURL)
                guard var object = try JSONSerialization.jsonObject(with: template) as? [String: Any] else {
                    outcomes[brand] = outcome(brand, .refused, nil, "invalid_template")
                    continue
                }
                replacePathPlaceholder(in: &object, with: helperURL.path)
                let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
                let destination = registrationDirectory(for: brand).appendingPathComponent("\(host).json")
                let directory = destination.deletingLastPathComponent()

                if !repair, fileSystem.info(destination) == nil, !existingAncestorIsUnsafe(directory) {
                    outcomes[brand] = outcome(brand, .changed, destination.path, "manifest_missing")
                    continue
                }
                guard ensureSafeDirectory(directory, create: repair) else {
                    outcomes[brand] = outcome(brand, .refused, destination.path, "unsafe_registration_directory")
                    continue
                }
                if let currentInfo = fileSystem.info(destination) {
                    guard currentInfo.kind == .regular, currentInfo.uid == effectiveUID else {
                        outcomes[brand] = outcome(brand, .refused, destination.path, "unsafe_manifest")
                        continue
                    }
                    if (try? fileSystem.read(destination)) == bytes {
                        outcomes[brand] = outcome(brand, .ready, destination.path, nil)
                        continue
                    }
                    guard repair else {
                        outcomes[brand] = outcome(brand, .changed, destination.path, "manifest_change_required")
                        continue
                    }
                } else if !repair {
                    outcomes[brand] = outcome(brand, .changed, destination.path, "manifest_missing")
                    continue
                }
                try fileSystem.writeAtomically(bytes, to: destination)
                guard let verifyInfo = fileSystem.info(destination),
                      verifyInfo.kind == .regular,
                      verifyInfo.uid == effectiveUID,
                      (try? fileSystem.read(destination)) == bytes else {
                    outcomes[brand] = outcome(brand, .refused, destination.path, "manifest_verification_failed")
                    continue
                }
                changedAny = true
                outcomes[brand] = outcome(brand, .changed, destination.path, nil)
            } catch {
                outcomes[brand] = outcome(brand, .refused, nil, "registration_io")
            }
        }
        return BrowserHostRegistrationReport(outcomes: outcomes, changedAny: changedAny)
    }

    private func isBundledProductionHelper() -> Bool {
        let resolved = fileSystem.resolve(helperURL)
        let components = resolved.pathComponents
        guard resolved.lastPathComponent == "solstone-browser-host",
              components.count >= 4,
              components[components.count - 2] == "MacOS",
              components[components.count - 3] == "Contents",
              components[components.count - 4].hasSuffix(".app") else { return false }
        guard let info = fileSystem.info(resolved) else { return false }
        return info.kind == .regular && info.uid == effectiveUID && (info.mode & 0o111) != 0
    }

    private func validateHelperOwnership() -> Bool {
        let resolved = fileSystem.resolve(helperURL)
        guard let info = fileSystem.info(resolved), info.kind == .regular, info.uid == effectiveUID,
              (info.mode & 0o111) != 0 else { return false }
        return !hasSymlinkAncestor(helperURL)
    }

    private func ensureSafeDirectory(_ directory: URL, create: Bool) -> Bool {
        let root = home.path
        guard directory.path == root || directory.path.hasPrefix(root + "/") else { return false }
        let relative = String(directory.path.dropFirst(root.count)).split(separator: "/").map(String.init)
        guard let homeInfo = fileSystem.info(home), homeInfo.kind == .directory, homeInfo.uid == effectiveUID else { return false }
        var current = home
        for component in relative {
            current.appendPathComponent(component, isDirectory: true)
            if let info = fileSystem.info(current) {
                guard info.kind == .directory, info.uid == effectiveUID else { return false }
            } else if create {
                do { try fileSystem.createDirectory(current) } catch { return false }
                guard let info = fileSystem.info(current), info.kind == .directory, info.uid == effectiveUID else { return false }
            } else {
                return false
            }
        }
        return !hasSymlinkAncestor(directory)
    }

    private func hasSymlinkAncestor(_ url: URL) -> Bool {
        var current = URL(fileURLWithPath: "/")
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            if fileSystem.info(current)?.kind == .symlink { return true }
        }
        return false
    }

    private func registrationDirectory(for brand: BrowserBrand) -> URL {
        let suffix: String
        switch brand {
        case .chrome: suffix = "Library/Application Support/Google/Chrome/NativeMessagingHosts"
        case .edge: suffix = "Library/Application Support/Microsoft Edge/NativeMessagingHosts"
        case .firefox: suffix = "Library/Application Support/Mozilla/NativeMessagingHosts"
        }
        return home.appendingPathComponent(suffix, isDirectory: true)
    }

    private func hostName(in contract: URL, mode: BrowserHostRegistrationMode) -> String? {
        guard let data = try? fileSystem.read(contract.appendingPathComponent("authority.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hosts = root["hosts_and_ids"] as? [String: Any],
              let selected = hosts[mode == .production ? "production" : "dev"] as? [String: Any] else { return nil }
        return selected["host"] as? String
    }

    /// Missing ancestors are absent, not unsafe. A symlink or foreign owner refuses the browser.
    private func existingAncestorIsUnsafe(_ directory: URL) -> Bool {
        let root = home.path
        guard directory.path == root || directory.path.hasPrefix(root + "/") else { return true }
        guard let homeInfo = fileSystem.info(home), homeInfo.kind == .directory, homeInfo.uid == effectiveUID else { return true }
        let relative = String(directory.path.dropFirst(root.count)).split(separator: "/").map(String.init)
        var current = home
        for component in relative {
            current.appendPathComponent(component, isDirectory: true)
            guard let info = fileSystem.info(current) else { return false }
            if info.kind != .directory || info.uid != effectiveUID { return true }
        }
        return hasSymlinkAncestor(directory)
    }

    private func replacePathPlaceholder(in value: inout [String: Any], with path: String) {
        for key in Array(value.keys) {
            if value[key] as? String == "__PATH__" { value[key] = path }
            else if var nested = value[key] as? [String: Any] {
                replacePathPlaceholder(in: &nested, with: path)
                value[key] = nested
            }
            else if var array = value[key] as? [[String: Any]] {
                for index in array.indices { replacePathPlaceholder(in: &array[index], with: path) }
                value[key] = array
            }
        }
    }

    private func refusedAll(_ reason: String) -> BrowserHostRegistrationReport {
        let outcomes = Dictionary(uniqueKeysWithValues: BrowserBrand.allCases.map {
            ($0, outcome($0, .refused, nil, reason))
        })
        return BrowserHostRegistrationReport(outcomes: outcomes, changedAny: false)
    }

    private func outcome(_ brand: BrowserBrand, _ state: BrowserHostRegistrationState, _ path: String?, _ reason: String?) -> BrowserHostRegistrationOutcome {
        BrowserHostRegistrationOutcome(brand: brand, state: state, path: path, reasonCode: reason)
    }
}

#endif
