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

        let statusRequest = IPCRequest(
            id: UUID(),
            protocolVersion: SolMacIPCConstants.currentProtocolVersion,
            command: .status
        )

        let statusResponse = try? await SolMacClient.send(
            statusRequest,
            connectTimeout: .milliseconds(500),
            requestTimeout: .seconds(5)
        )

        let statusInfo: StatusInfo?
        if let statusResponse, case .ok(.status(let info)) = statusResponse.result {
            print("OK: app running")
            print("OK: IPC reachable")
            statusInfo = info
        } else if statusResponse != nil {
            print("WARN: app running: responded unexpectedly")
            print("WARN: IPC reachable: responded unexpectedly")
            statusInfo = nil
        } else {
            print("WARN: app running: not running")
            print("WARN: IPC reachable: n/a — app not running")
            statusInfo = nil
        }

        printPermission(label: "screen-recording", granted: statusInfo?.screenRecordingGranted, appReachable: statusInfo != nil)
        printPermission(label: "microphone", granted: statusInfo?.microphoneGranted, appReachable: statusInfo != nil)

        await printServerReachability()
        printCapturesWritable()
    }
}

private func printPermission(label: String, granted: Bool?, appReachable: Bool) {
    guard appReachable else {
        print("WARN: \(label): unknown — start solstone to check")
        return
    }
    switch granted {
    case .some(true):
        print("OK: \(label): granted")
    case .some(false):
        print("FAIL: \(label): denied")
    case .none:
        print("WARN: \(label): unknown — start solstone to check")
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
