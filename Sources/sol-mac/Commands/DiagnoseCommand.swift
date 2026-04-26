import ArgumentParser
import Foundation
import SolstoneCore

struct DiagnoseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagnose",
        abstract: "run local cli diagnostics."
    )

    func run() async throws {
        let appPath = resolveAppBundlePath()
        if let appPath {
            print("OK: app installed: \(appPath.path)")
        } else {
            print("FAIL: app installed: not found")
        }

        let pingRequest = IPCRequest(
            id: UUID(),
            protocolVersion: SolMacIPCConstants.currentProtocolVersion,
            command: .ping
        )

        let pingResult = try? await SolMacClient.send(
            pingRequest,
            connectTimeout: .milliseconds(500),
            requestTimeout: .seconds(1)
        )

        if let pingResult, case .ok(.pong) = pingResult.result {
            print("OK: app running")
            print("OK: IPC reachable")
        } else if pingResult != nil {
            print("WARN: app running: responded unexpectedly")
            print("WARN: IPC reachable: responded unexpectedly")
        } else {
            print("WARN: app running: not running")
            print("WARN: IPC reachable: n/a — app not running")
        }

        if screenCaptureAccessGranted() {
            print("OK: screen TCC: granted")
        } else {
            print("FAIL: screen TCC: not granted")
        }

        print("WARN: mic TCC: unknown (cli cannot probe without AVFoundation)")

        await printServerReachability()
        printCapturesWritable()
    }
}

private func printServerReachability() async {
    guard let serverValue = cfRead(key: "serverURL") as? String else {
        print("WARN: server not configured")
        return
    }

    let trimmed = serverValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        print("WARN: server not configured")
        return
    }

    guard let url = URL(string: trimmed) else {
        print("FAIL: server unreachable: invalid url")
        return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "HEAD"
    request.timeoutInterval = 5

    do {
        let (_, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, (200..<400).contains(httpResponse.statusCode) {
            print("OK: server reachable")
        } else if let httpResponse = response as? HTTPURLResponse {
            print("FAIL: server unreachable: HTTP \(httpResponse.statusCode)")
        } else {
            print("FAIL: server unreachable: invalid response")
        }
    } catch {
        print("FAIL: server unreachable: \(error.localizedDescription)")
    }
}

private func printCapturesWritable() {
    let fileManager = FileManager.default
    let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let capturesDirectory = appSupport.appendingPathComponent("Solstone/captures", isDirectory: true)

    do {
        try fileManager.createDirectory(at: capturesDirectory, withIntermediateDirectories: true)
        let tempURL = capturesDirectory.appendingPathComponent(".sol-mac-write-check-\(UUID().uuidString)")
        try Data().write(to: tempURL)
        try fileManager.removeItem(at: tempURL)
        print("OK: captures dir writable")
    } catch {
        print("FAIL: captures dir writable: \(error.localizedDescription)")
    }
}
