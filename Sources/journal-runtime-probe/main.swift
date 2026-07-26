// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import JournalRuntime

private enum ProbeRegime: String {
    case production
    case plain

    var intendedSourceShape: EntryShape {
        switch self {
        case .production:
            return .uvPolyglot
        case .plain:
            return .uvPlainShebang
        }
    }
}

private enum EntryShape: String {
    case uvPolyglot
    case uvPlainShebang
    case native

    var isUvAuthored: Bool {
        switch self {
        case .uvPolyglot, .uvPlainShebang:
            return true
        case .native:
            return false
        }
    }
}

private struct Options {
    var appURL: URL
    var regimes: [ProbeRegime]
}

private struct BundleResources {
    var appURL: URL
    var uvURL: URL
    var bundledPythonURL: URL
    var wheelhouseURL: URL
}

private struct RegimeWorkspace {
    var workspaceURL: URL
    var runtimeRootURL: URL
}

private struct SourceShapeMetrics {
    var interpreterPath: String
    var interpreterPathLength: Int
    var shebangLength: Int
    var containsWhitespace: Bool
    var expectedShape: EntryShape
}

private struct EntryInspection {
    var name: String
    var shape: EntryShape
    var interpreterPath: String?
    var interpreterPathLength: Int?
    var interpreterContainsWhitespace: Bool?
    var rawSymlinkDestination: String
}

private struct RunResult {
    var status: Int32
    var stdout: String
    var stderr: String
}

private struct ProbeFailure: LocalizedError {
    var message: String

    var errorDescription: String? {
        message
    }
}

@main
enum JournalRuntimeProbe {
    private static let installTimeoutSeconds: Int64 = 240
    private static let verifyTimeoutSeconds: Int64 = 60
    private static let generationHashByteCount = 16
    private static let stagingUUIDByteCount = 36
    private static let inspectionByteLimit = 4096
    private static let bundledPythonLinkName = "python3.13"
    private static let journalPythonRelativePath = "tools/solstone-journal/bin/python"

    static func main() async {
        let status = await run(arguments: Array(CommandLine.arguments.dropFirst()))
        Darwin.exit(status)
    }

    private static func run(arguments: [String]) async -> Int32 {
        do {
            let options = try parse(arguments: arguments)
            let resources = try resolveResources(appURL: options.appURL)
            var failedRegimes: [ProbeRegime] = []

            for regime in options.regimes {
                let passed = await run(regime: regime, resources: resources)
                if !passed {
                    failedRegimes.append(regime)
                }
            }

            if failedRegimes.isEmpty {
                print("journal-runtime-probe: all regimes passed")
                return 0
            }
            let names = failedRegimes.map(\.rawValue).joined(separator: ", ")
            fputs("journal-runtime-probe: failed regimes: \(names)\n", stderr)
            return 1
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 2
        }
    }

    private static func parse(arguments: [String]) throws -> Options {
        var appPath: String?
        var regimeText = "both"
        var index = arguments.startIndex

        while index < arguments.endIndex {
            let argument = arguments[index]
            switch argument {
            case "--app":
                index = arguments.index(after: index)
                guard index < arguments.endIndex else {
                    throw ProbeFailure(message: usage("missing value for --app"))
                }
                appPath = arguments[index]
            case "--regime":
                index = arguments.index(after: index)
                guard index < arguments.endIndex else {
                    throw ProbeFailure(message: usage("missing value for --regime"))
                }
                regimeText = arguments[index]
            case "--help", "-h":
                throw ProbeFailure(message: usage(nil))
            default:
                throw ProbeFailure(message: usage("unknown argument \(argument)"))
            }
            index = arguments.index(after: index)
        }

        guard let appPath else {
            throw ProbeFailure(message: usage("missing --app"))
        }

        let regimes: [ProbeRegime]
        switch regimeText {
        case "production":
            regimes = [.production]
        case "plain":
            regimes = [.plain]
        case "both":
            regimes = [.production, .plain]
        default:
            throw ProbeFailure(message: usage("invalid --regime \(regimeText)"))
        }

        return Options(
            appURL: URL(fileURLWithPath: appPath).resolvingSymlinksInPath().standardizedFileURL,
            regimes: regimes
        )
    }

    private static func usage(_ error: String?) -> String {
        var text = ""
        if let error {
            text += "error: \(error)\n"
        }
        text += "usage: journal-runtime-probe --app <path/to/journal.app> [--regime production|plain|both]"
        return text
    }

    private static func resolveResources(appURL: URL) throws -> BundleResources {
        try requireDirectory(appURL, what: "journal.app")
        let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let uvURL = resourcesURL.appendingPathComponent("uv")
        let bundledPythonURL = resourcesURL.appendingPathComponent("python/bin/python3.13")
        let wheelhouseURL = resourcesURL.appendingPathComponent("wheelhouse", isDirectory: true)

        try requireFile(uvURL, what: "bundled uv")
        try requireFile(bundledPythonURL, what: "bundled python")
        try requireDirectory(wheelhouseURL, what: "bundled wheelhouse")

        return BundleResources(
            appURL: appURL,
            uvURL: uvURL,
            bundledPythonURL: bundledPythonURL,
            wheelhouseURL: wheelhouseURL
        )
    }

    private static func run(regime: ProbeRegime, resources: BundleResources) async -> Bool {
        let workspace: RegimeWorkspace
        do {
            workspace = try makeWorkspace(for: regime)
        } catch {
            fputs("[\(regime.rawValue)] FAIL\n\(error.localizedDescription)\n", stderr)
            return false
        }

        let fileManager = FileManager.default
        defer {
            try? fileManager.removeItem(at: workspace.workspaceURL)
        }

        do {
            try fileManager.createDirectory(at: workspace.workspaceURL, withIntermediateDirectories: true)
            let wrapperDirURL = workspace.workspaceURL.appendingPathComponent("wrappers", isDirectory: true)
            let sourceMetrics = sourceShapeMetrics(runtimeRootURL: workspace.runtimeRootURL)
            try assertRegimeSourceShape(sourceMetrics, regime: regime)

            print("[\(regime.rawValue)] runtime root: \(workspace.runtimeRootURL.path)")
            print("[\(regime.rawValue)] wrapper dir: \(wrapperDirURL.path)")
            print("[\(regime.rawValue)] timeouts: install=\(installTimeoutSeconds)s verify=\(verifyTimeoutSeconds)s")
            print(
                "[\(regime.rawValue)] source branch predicate: \(sourceMetrics.expectedShape.rawValue) " +
                    "(interpreter-bytes=\(sourceMetrics.interpreterPathLength), " +
                    "shebang-length=\(sourceMetrics.shebangLength), " +
                    "whitespace=\(sourceMetrics.containsWhitespace))"
            )

            let materializer = RuntimeMaterializer(
                runtimeRootURL: workspace.runtimeRootURL,
                uvBinaryURL: resources.uvURL,
                bundledPythonURL: resources.bundledPythonURL,
                wheelhouseURL: resources.wheelhouseURL,
                wrapperDirURL: wrapperDirURL,
                installTimeout: .seconds(installTimeoutSeconds),
                verifyTimeout: .seconds(verifyTimeoutSeconds)
            )

            let runtime: MaterializedRuntime
            do {
                runtime = try await materializer.materialize(excludingLiveKey: nil)
            } catch {
                throw ProbeFailure(message: error.localizedDescription)
            }

            try inspect(runtime: runtime, resources: resources, regime: regime)
            try assertVersionExecutable(runtime.layout.solBinary, name: "sol")
            try assertVersionExecutable(runtime.layout.journalBinary, name: "journal")
            try assertDee5409Invariant(runtime: runtime, resources: resources)

            print("[\(regime.rawValue)] PASS key=\(runtime.key)")
            return true
        } catch {
            fputs("[\(regime.rawValue)] FAIL\n\(error.localizedDescription)\n", stderr)
            return false
        }
    }

    private static func makeWorkspace(for regime: ProbeRegime) throws -> RegimeWorkspace {
        switch regime {
        case .production:
            return try makeProductionWorkspace()
        case .plain:
            return try makePlainWorkspace()
        }
    }

    private static func makeProductionWorkspace() throws -> RegimeWorkspace {
        let workspaceURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("journal-runtime-probe-\(shortUniqueToken())", isDirectory: true)
        let baseComponent = "runtime root with space"
        let baseRootURL = workspaceURL.appendingPathComponent(baseComponent, isDirectory: true)
        let targetLength = productionInterpreterPathLength()
        let baseLength = finalInterpreterPathLength(runtimeRootURL: baseRootURL)
        let paddingCount = targetLength - baseLength
        guard paddingCount >= 0 else {
            throw ProbeFailure(
                message: "error: cannot construct production regime: base interpreter path length \(baseLength) exceeds target \(targetLength)"
            )
        }
        let rootComponent = baseComponent + String(repeating: "p", count: paddingCount)
        let runtimeRootURL = workspaceURL.appendingPathComponent(rootComponent, isDirectory: true)
        let actualLength = finalInterpreterPathLength(runtimeRootURL: runtimeRootURL)
        guard actualLength == targetLength else {
            throw ProbeFailure(
                message: "error: cannot construct production regime: expected interpreter length \(targetLength), observed \(actualLength)"
            )
        }
        return RegimeWorkspace(workspaceURL: workspaceURL, runtimeRootURL: runtimeRootURL)
    }

    private static func makePlainWorkspace() throws -> RegimeWorkspace {
        let workspaceURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("jrp-\(shortUniqueToken())", isDirectory: true)
        let runtimeRootURL = workspaceURL.appendingPathComponent("r", isDirectory: true)
        let metrics = sourceShapeMetrics(runtimeRootURL: runtimeRootURL)
        guard !metrics.containsWhitespace else {
            throw ProbeFailure(message: "error: plain regime path unexpectedly contains whitespace: \(metrics.interpreterPath)")
        }
        guard metrics.shebangLength <= 126 else {
            throw ProbeFailure(
                message: "error: plain regime shebang length \(metrics.shebangLength) exceeds 126 for \(metrics.interpreterPath)"
            )
        }
        return RegimeWorkspace(workspaceURL: workspaceURL, runtimeRootURL: runtimeRootURL)
    }

    private static func inspect(
        runtime: MaterializedRuntime,
        resources: BundleResources,
        regime: ProbeRegime
    ) throws {
        let binEntries = try exportedBinEntries(in: runtime.layout.binDir)
        print("[\(regime.rawValue)] shape table:")
        print("name\tclassification\tinterpreter-bytes\tinterpreter-whitespace\traw-symlink")

        for entry in binEntries {
            let inspection = try inspect(entry: entry, runtimeRootURL: runtime.layout.rootURL.deletingLastPathComponent())
            print(shapeTableLine(inspection))

            guard !inspection.rawSymlinkDestination.hasPrefix("/") else {
                throw ProbeFailure(
                    message: "error: \(regime.rawValue) \(inspection.name) symlink is absolute: \(inspection.rawSymlinkDestination)"
                )
            }

            if inspection.shape.isUvAuthored {
                guard inspection.shape == .uvPolyglot else {
                    throw ProbeFailure(
                        message: "error: \(regime.rawValue) \(inspection.name) final shape mismatch: expected uvPolyglot, observed \(inspection.shape.rawValue)"
                    )
                }
                guard let interpreterPath = inspection.interpreterPath else {
                    throw ProbeFailure(message: "error: \(regime.rawValue) \(inspection.name) missing uv interpreter path")
                }
                _ = try canonicalExistingPath(interpreterPath)
            }
        }

        if regime == .production {
            try assertProductionLength(in: binEntries, runtime: runtime)
        }
    }

    private static func exportedBinEntries(in binDir: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: binDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.lastPathComponent != bundledPythonLinkName }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func inspect(entry: URL, runtimeRootURL: URL) throws -> EntryInspection {
        let name = entry.lastPathComponent
        let rawDestination: String
        do {
            rawDestination = try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
        } catch {
            throw ProbeFailure(message: "error: \(name) is not a symlink: \(entry.path)")
        }

        let resolved = entry.resolvingSymlinksInPath().standardizedFileURL
        let data = try Data(contentsOf: resolved)
        let prefix = Data(data.prefix(inspectionByteLimit))
        if containsStagingSegment(inPathData: prefix) {
            throw ProbeFailure(message: "error: \(name) inspected prefix contains .tmp- segment")
        }

        let shape = classify(prefix: prefix, runtimeRootURL: runtimeRootURL)
        let interpreter = interpreterPath(for: shape, prefix: prefix)
        return EntryInspection(
            name: name,
            shape: shape,
            interpreterPath: interpreter,
            interpreterPathLength: interpreter?.utf8.count,
            interpreterContainsWhitespace: interpreter.map(containsWhitespace),
            rawSymlinkDestination: rawDestination
        )
    }

    private static func shapeTableLine(_ inspection: EntryInspection) -> String {
        let length = inspection.interpreterPathLength.map(String.init) ?? "-"
        let whitespace = inspection.interpreterContainsWhitespace.map(String.init) ?? "-"
        return "\(inspection.name)\t\(inspection.shape.rawValue)\t\(length)\t\(whitespace)\t\(inspection.rawSymlinkDestination)"
    }

    private static func classify(prefix data: Data, runtimeRootURL: URL) -> EntryShape {
        guard let text = String(data: data, encoding: .utf8) else {
            return .native
        }
        let lines = text.components(separatedBy: "\n")
        if isUvPolyglot(lines) {
            return .uvPolyglot
        }
        if let line = lines.first,
           let interpreter = uvPlainShebangInterpreterPath(from: line),
           pathIsLexicallyUnderRoot(interpreter, rootURL: runtimeRootURL) {
            return .uvPlainShebang
        }
        return .native
    }

    private static func isUvPolyglot(_ lines: [String]) -> Bool {
        lines.count >= 2 && lines[0] == "#!/bin/sh" && lines[1].hasPrefix("'''exec' '")
    }

    private static func interpreterPath(for shape: EntryShape, prefix data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let lines = text.components(separatedBy: "\n")
        switch shape {
        case .uvPolyglot:
            guard lines.count >= 2 else { return nil }
            return uvPolyglotInterpreterPath(from: lines[1])
        case .uvPlainShebang:
            guard let line = lines.first else { return nil }
            return uvPlainShebangInterpreterPath(from: line)
        case .native:
            return nil
        }
    }

    private static func uvPlainShebangInterpreterPath(from line: String) -> String? {
        guard line.hasPrefix("#!") else { return nil }
        let path = String(line.dropFirst(2))
        guard path.hasPrefix("/") else { return nil }
        return path
    }

    private static func uvPolyglotInterpreterPath(from line: String) -> String? {
        let prefix = "'''exec' "
        guard line.hasPrefix(prefix) else { return nil }
        var index = line.index(line.startIndex, offsetBy: prefix.count)
        guard index < line.endIndex, line[index] == "'" else { return nil }
        index = line.index(after: index)

        var value = ""
        while index < line.endIndex {
            let character = line[index]
            if character == "'" {
                let backslashIndex = line.index(after: index)
                if backslashIndex < line.endIndex,
                   line[backslashIndex] == "\\" {
                    let escapedQuoteIndex = line.index(after: backslashIndex)
                    if escapedQuoteIndex < line.endIndex,
                       line[escapedQuoteIndex] == "'" {
                        let reopenQuoteIndex = line.index(after: escapedQuoteIndex)
                        if reopenQuoteIndex < line.endIndex,
                           line[reopenQuoteIndex] == "'" {
                            value.append("'")
                            index = line.index(after: reopenQuoteIndex)
                            continue
                        }
                    }
                }
                return value
            }
            value.append(character)
            index = line.index(after: index)
        }
        return nil
    }

    private static func assertProductionLength(in entries: [URL], runtime: MaterializedRuntime) throws {
        let targetLength = productionInterpreterPathLength()
        for entry in entries where entry.lastPathComponent == "journal" {
            let inspection = try inspect(entry: entry, runtimeRootURL: runtime.layout.rootURL.deletingLastPathComponent())
            guard let observed = inspection.interpreterPathLength else {
                throw ProbeFailure(message: "error: production journal entry has no interpreter path")
            }
            guard observed == targetLength else {
                throw ProbeFailure(
                    message: "error: production interpreter length mismatch: expected \(targetLength), observed \(observed)"
                )
            }
        }
    }

    private static func assertRegimeSourceShape(_ metrics: SourceShapeMetrics, regime: ProbeRegime) throws {
        guard metrics.expectedShape == regime.intendedSourceShape else {
            throw ProbeFailure(
                message: "error: \(regime.rawValue) source shape mismatch: expected \(regime.intendedSourceShape.rawValue), observed \(metrics.expectedShape.rawValue)"
            )
        }
    }

    private static func assertVersionExecutable(_ executable: URL, name: String) throws {
        let result = try runExecutable(executable, arguments: ["--version"])
        let expected = "solstone \(BundleConfig.solstonePinVersion)\n"
        guard result.status == 0 else {
            throw ProbeFailure(
                message: "error: \(name) --version exited \(result.status)\nstderr:\n\(result.stderr)"
            )
        }
        guard result.stdout == expected else {
            throw ProbeFailure(
                message: "error: \(name) --version stdout mismatch: expected \(String(reflecting: expected)), observed \(String(reflecting: result.stdout))"
            )
        }
    }

    private static func assertDee5409Invariant(runtime: MaterializedRuntime, resources: BundleResources) throws {
        let venvPython = runtime.layout.rootURL.appendingPathComponent(journalPythonRelativePath)
        guard isSymbolicLink(venvPython) else {
            throw ProbeFailure(message: "error: dee5409 invariant failed: venv python is not a symlink at \(venvPython.path)")
        }
        let resolvedPython = try canonicalExistingPath(venvPython.path)
        let runtimeRoot = try canonicalExistingPath(runtime.layout.rootURL.path)
        let bundledPython = try canonicalExistingPath(resources.bundledPythonURL.path)
        guard !pathIsUnderRoot(resolvedPython, root: runtimeRoot),
              resolvedPython == bundledPython else {
            throw ProbeFailure(
                message: "error: dee5409 invariant failed: venv python resolved to \(resolvedPython), expected bundled interpreter outside runtime root at \(bundledPython)"
            )
        }
        print("dee5409 invariant: venv python resolves outside runtime root to bundled interpreter: \(resolvedPython)")
    }

    private static func runExecutable(_ executable: URL, arguments: [String]) throws -> RunResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw ProbeFailure(message: "error: failed to execute \(executable.path): \(error.localizedDescription)")
        }
        process.waitUntilExit()
        return RunResult(
            status: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private static func requireFile(_ url: URL, what: String) throws {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw ProbeFailure(message: "error: \(what) missing at \(url.path)")
        }
    }

    private static func requireDirectory(_ url: URL, what: String) throws {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ProbeFailure(message: "error: \(what) missing at \(url.path)")
        }
    }

    private static func sourceShapeMetrics(runtimeRootURL: URL) -> SourceShapeMetrics {
        let stagingSegment = ".tmp-" + String(repeating: "0", count: stagingUUIDByteCount)
        let interpreter = runtimeRootURL
            .appendingPathComponent(stagingSegment, isDirectory: true)
            .appendingPathComponent(journalPythonRelativePath)
            .path
        let pathLength = interpreter.utf8.count
        let shebangLength = 2 + pathLength
        let whitespace = containsWhitespace(interpreter)
        return SourceShapeMetrics(
            interpreterPath: interpreter,
            interpreterPathLength: pathLength,
            shebangLength: shebangLength,
            containsWhitespace: whitespace,
            expectedShape: expectedUvSourceShape(interpreterPath: interpreter)
        )
    }

    private static func expectedUvSourceShape(interpreterPath: String) -> EntryShape {
        let shebangLength = 2 + interpreterPath.utf8.count
        if containsWhitespace(interpreterPath) || shebangLength > 126 {
            return .uvPolyglot
        }
        return .uvPlainShebang
    }

    private static func productionInterpreterPathLength() -> Int {
        finalInterpreterPathLength(runtimeRootURL: SolstoneRuntimeLayout.defaultRootURL)
    }

    private static func finalInterpreterPathLength(runtimeRootURL: URL) -> Int {
        runtimeRootURL.path.utf8.count
            + 1
            + generationKeyByteCount()
            + 1
            + journalPythonRelativePath.utf8.count
    }

    private static func generationKeyByteCount() -> Int {
        "\(BundleConfig.solstonePinVersion)_py\(BundleConfig.bundledPythonBuild)_".utf8.count
            + generationHashByteCount
    }

    private static func containsWhitespace(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.whitespaces.contains($0) }
    }

    private static func containsStagingSegment(inPathData data: Data) -> Bool {
        let slash = UInt8(ascii: "/")
        var segmentStart = data.startIndex
        var index = data.startIndex
        while index <= data.endIndex {
            if index == data.endIndex || data[index] == slash {
                if segmentHasStagingPrefix(data[segmentStart..<index]) {
                    return true
                }
                if index == data.endIndex {
                    break
                }
                segmentStart = data.index(after: index)
            }
            index = data.index(after: index)
        }
        return false
    }

    private static func segmentHasStagingPrefix(_ segment: Data.SubSequence) -> Bool {
        let prefix = Data(".tmp-".utf8)
        guard segment.count >= prefix.count else { return false }
        return Data(segment.prefix(prefix.count)) == prefix
    }

    private static func pathIsLexicallyUnderRoot(_ path: String, rootURL: URL) -> Bool {
        pathSpellings(for: rootURL).contains { root in
            path == root || path.hasPrefix(root + "/")
        }
    }

    private static func pathSpellings(for url: URL) -> [String] {
        var values = [
            url.standardizedFileURL.path,
            url.resolvingSymlinksInPath().standardizedFileURL.path
        ]
        if let canonical = try? canonicalExistingPath(url.path) {
            values.append(canonical)
        }
        return unique(values)
    }

    private static func pathIsUnderRoot(_ path: String, root: String) -> Bool {
        path != root && path.hasPrefix(root + "/")
    }

    private static func canonicalExistingPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else {
            return false
        }
        return (metadata.st_mode & S_IFMT) == S_IFLNK
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }

    private static func shortUniqueToken() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }
}
