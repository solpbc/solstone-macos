// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation

public enum SolstoneCoreAbout {
    public static let separator = " · "

    public enum SysctlResult: Sendable {
        case success(Int32)
        case failure(Int32)
    }

    private static let buildOperatingSystems: Set<String> = [
        "macos", "ios", "ipados", "watchos", "android"
    ]

    public struct Resource: Decodable, Sendable, Equatable {
        public let protocolVersion: Int
        public let version: String
        public let build: String?
        public let os: String
        public let osVersion: String
        public let arch: String
        public let about: String

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol_version"
            case version
            case build
            case os
            case osVersion = "os_version"
            case arch
            case about
        }
    }

    public struct NativeSnapshot: Codable, Sendable, Equatable {
        public let protocolVersion: Int
        public let os: String
        public let osVersion: String
        public let arch: String
        public let journalLine: String
        public let journalCurrent: Bool
        public let journalSeenAtEpochSecs: Int64?

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol_version"
            case os
            case osVersion = "os_version"
            case arch
            case journalLine = "journal_line"
            case journalCurrent = "journal_current"
            case journalSeenAtEpochSecs = "journal_seen_at_epoch_secs"
        }

        public func object() throws -> [String: Any] {
            let data = try JSONEncoder().encode(self)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "Snapshot did not encode as an object"))
            }
            return object
        }

        public func markedNotCurrent() -> NativeSnapshot {
            NativeSnapshot(
                protocolVersion: protocolVersion,
                os: os,
                osVersion: osVersion,
                arch: arch,
                journalLine: journalLine,
                journalCurrent: false,
                journalSeenAtEpochSecs: journalLine == "journal unknown" ? nil : journalSeenAtEpochSecs
            )
        }

        public func clearingJournal() -> NativeSnapshot {
            NativeSnapshot(
                protocolVersion: protocolVersion,
                os: os,
                osVersion: osVersion,
                arch: arch,
                journalLine: "journal unknown",
                journalCurrent: false,
                journalSeenAtEpochSecs: nil
            )
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(protocolVersion, forKey: .protocolVersion)
            try container.encode(os, forKey: .os)
            try container.encode(osVersion, forKey: .osVersion)
            try container.encode(arch, forKey: .arch)
            try container.encode(journalLine, forKey: .journalLine)
            try container.encode(journalCurrent, forKey: .journalCurrent)
            if let journalSeenAtEpochSecs {
                try container.encode(journalSeenAtEpochSecs, forKey: .journalSeenAtEpochSecs)
            } else {
                try container.encodeNil(forKey: .journalSeenAtEpochSecs)
            }
        }
    }

    public static func renderLine(
        name: String,
        version: String?,
        build: String? = nil,
        os: String? = nil,
        osVersion: String? = nil,
        arch: String? = nil,
        age: String? = nil
    ) -> String {
        guard let version, !version.isEmpty else {
            return name == "journal" ? "journal unknown" : "\(name) unknown"
        }

        var components = ["\(name) \(version.trimmingLeadingV())"]
        if let build, !build.isEmpty, let os, buildOperatingSystems.contains(os) {
            components[0] += " (\(build))"
        }
        if let os, !os.isEmpty {
            components.append(os + (osVersion.map { $0.isEmpty ? "" : " \($0)" } ?? ""))
        }
        if let arch, !arch.isEmpty {
            components.append(normalizedArch(arch))
        }
        var line = components.joined(separator: separator)
        if let age {
            line += separator + "last seen " + age
        }
        return line
    }

    public static func decodeResource(_ data: Data) -> Resource? {
        guard let resource = try? JSONDecoder().decode(Resource.self, from: data),
              resource.protocolVersion == 1,
              !resource.version.isEmpty,
              !resource.version.trimmingLeadingV().isEmpty,
              !resource.about.isEmpty,
              resource.build.map({ !$0.isEmpty }) ?? true,
              renderLine(
                name: "journal",
                version: resource.version,
                build: resource.build,
                os: resource.os,
                osVersion: resource.osVersion,
                arch: resource.arch
              ) == resource.about else {
            return nil
        }

        return Resource(
            protocolVersion: resource.protocolVersion,
            version: resource.version,
            build: resource.osBuildAllowed ? resource.build : nil,
            os: resource.os,
            osVersion: resource.osVersion,
            arch: resource.arch,
            about: resource.about
        )
    }

    public static func captureBlock(
        appVersion: String,
        appBuild: String?,
        osVersion: String,
        arch: String?,
        journalVersion: String?,
        journalBuild: String? = nil,
        journalOS: String? = nil,
        journalOSVersion: String? = nil,
        journalArch: String? = nil,
        journalAge: String? = nil
    ) -> String {
        let appLine = renderLine(
            name: "solstone macos app",
            version: appVersion,
            build: appBuild,
            os: "macos",
            osVersion: osVersion,
            arch: arch
        )
        let journalLine = renderLine(
            name: "journal",
            version: journalVersion,
            build: journalBuild,
            os: journalOS,
            osVersion: journalOSVersion,
            arch: journalArch,
            age: journalAge
        )
        return appLine + "\n" + journalLine
    }

    public static func numericOSVersion(_ version: OperatingSystemVersion) -> String {
        if version.patchVersion == 0 {
            return "\(version.majorVersion).\(version.minorVersion)"
        }
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    public static func decodeNativeSnapshot(_ data: Data) -> NativeSnapshot? {
        let requiredKeys: Set<String> = [
            "protocol_version", "os", "os_version", "arch", "journal_line",
            "journal_current", "journal_seen_at_epoch_secs"
        ]
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == requiredKeys,
              let snapshot = try? JSONDecoder().decode(NativeSnapshot.self, from: data),
              snapshot.protocolVersion == 1,
              snapshot.os.unicodeScalars.allSatisfy({ $0 != "\r" && $0 != "\n" }),
              snapshot.osVersion.unicodeScalars.allSatisfy({ $0 != "\r" && $0 != "\n" }),
              snapshot.arch.unicodeScalars.allSatisfy({ $0 != "\r" && $0 != "\n" }),
              snapshot.journalLine.unicodeScalars.count >= 9,
              snapshot.journalLine.unicodeScalars.count <= 8192,
              snapshot.journalLine.hasPrefix("journal "),
              !snapshot.journalLine.contains("\r"),
              !snapshot.journalLine.contains("\n"),
              !snapshot.journalLine.contains(separator + "last seen "),
              snapshot.journalSeenAtEpochSecs.map({ $0 >= 0 }) ?? true else {
            return nil
        }
        if snapshot.journalLine == "journal unknown" {
            guard !snapshot.journalCurrent, snapshot.journalSeenAtEpochSecs == nil else { return nil }
        }
        return snapshot
    }

    public static func nativeMacOSArch(
        procTranslated: SysctlResult,
        hwMachine: String?
    ) -> String? {
        switch procTranslated {
        case .success(1):
            return "arm64"
        case .success(0), .failure(ENOENT):
            guard let hwMachine, !hwMachine.isEmpty else { return nil }
            return normalizedArch(hwMachine)
        default:
            return nil
        }
    }

    public static func nativeMacOSArch() -> String? {
        let machine = sysctlString("hw.machine")
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let procResult: SysctlResult
        if sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0, size == MemoryLayout<Int32>.size {
            procResult = .success(translated)
        } else {
            procResult = .failure(errno)
        }
        return nativeMacOSArch(procTranslated: procResult, hwMachine: machine)
    }

    public static func nativeSnapshot(
        os: String,
        osVersion: String,
        arch: String?,
        journalVersion: String?,
        journalBuild: String? = nil,
        journalOS: String? = nil,
        journalOSVersion: String? = nil,
        journalArch: String? = nil,
        journalCurrent: Bool,
        versionObservedAt: Date?
    ) -> NativeSnapshot {
        let observedEpoch = versionObservedAt.flatMap(nonnegativeEpochSeconds)
        let hasObservation = observedEpoch != nil
        let line = renderLine(
            name: "journal",
            version: journalVersion,
            build: hasObservation ? journalBuild : nil,
            os: hasObservation ? journalOS : nil,
            osVersion: hasObservation ? journalOSVersion : nil,
            arch: hasObservation ? journalArch : nil
        )
        let isUnknown = line == "journal unknown"
        return NativeSnapshot(
            protocolVersion: 1,
            os: singleLine(os),
            osVersion: singleLine(osVersion),
            arch: singleLine(arch.map(normalizedArch) ?? ""),
            journalLine: line,
            journalCurrent: !isUnknown && hasObservation && journalCurrent,
            journalSeenAtEpochSecs: isUnknown ? nil : observedEpoch
        )
    }

    public static func normalizedArch(_ value: String) -> String {
        switch value {
        case "aarch64", "ARM64", "arm64-v8a", "arm64": return "arm64"
        case "amd64", "x64", "AMD64", "x86_64": return "x86_64"
        default: return value
        }
    }

    private static func nonnegativeEpochSeconds(_ date: Date) -> Int64? {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) else { return nil }
        return Int64(seconds)
    }

    private static func singleLine(_ value: String) -> String {
        value.filter { $0 != "\r" && $0 != "\n" }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

private extension String {
    func trimmingLeadingV() -> String {
        String(drop(while: { $0 == "v" }))
    }
}

private extension SolstoneCoreAbout.Resource {
    var osBuildAllowed: Bool {
        ["macos", "ios", "ipados", "watchos", "android"].contains(os)
    }
}
