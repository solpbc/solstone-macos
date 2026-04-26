import ArgumentParser
import Foundation
import SolstoneCore

let scalarWritableKeys: Set<String> = [
    "serverURL",
    "serverKey",
    "cacheRetentionDays",
    "syncPaused",
    "debugSegments",
    "debugKeepRejectedAudio",
    "microphoneGain",
    "silenceMusic",
    "excludePrivateBrowsing"
]

struct ConfigParseError: Error {
    let reason: String
}

func cfRead(
    key: String,
    domain: CFString = SolMacIPCConstants.appBundleIdentifier as CFString
) -> Any? {
    CFPreferencesCopyAppValue(key as CFString, domain)
}

@discardableResult
func cfWrite(
    key: String,
    value: Any?,
    domain: CFString = SolMacIPCConstants.appBundleIdentifier as CFString
) -> Bool {
    CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, domain)
    return CFPreferencesAppSynchronize(domain)
}

func parseScalar(key: String, value: String) throws -> Any {
    switch key {
    case "serverURL", "serverKey":
        return value
    case "cacheRetentionDays":
        guard let intValue = Int(value) else {
            throw ConfigParseError(reason: "expected integer")
        }
        return NSNumber(value: intValue)
    case "microphoneGain":
        guard let floatValue = Float(value) else {
            throw ConfigParseError(reason: "expected float")
        }
        return NSNumber(value: floatValue)
    case "syncPaused", "debugSegments", "debugKeepRejectedAudio", "silenceMusic", "excludePrivateBrowsing":
        switch value.lowercased() {
        case "true", "1", "yes":
            return NSNumber(value: true)
        case "false", "0", "no":
            return NSNumber(value: false)
        default:
            throw ConfigParseError(reason: "expected true|false|1|0|yes|no")
        }
    default:
        throw ConfigParseError(reason: "unsupported key")
    }
}

func renderValue(key: String, value: Any?) -> String {
    guard let value else { return "<unset>" }

    if let data = value as? Data {
        if let object = try? JSONSerialization.jsonObject(with: data),
           let encoded = try? JSONSerialization.data(withJSONObject: object),
           let string = String(data: encoded, encoding: .utf8) {
            return string
        }
        return "<unrenderable>"
    }

    if let array = value as? [Any],
       JSONSerialization.isValidJSONObject(array),
       let data = try? JSONSerialization.data(withJSONObject: array),
       let string = String(data: data, encoding: .utf8) {
        return string
    }

    if let dictionary = value as? [String: Any],
       JSONSerialization.isValidJSONObject(dictionary),
       let data = try? JSONSerialization.data(withJSONObject: dictionary),
       let string = String(data: data, encoding: .utf8) {
        return string
    }

    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        return number.stringValue
    }

    return String(describing: value)
}

func notifyReload() async {
    let request = IPCRequest(
        id: UUID(),
        protocolVersion: SolMacIPCConstants.currentProtocolVersion,
        command: .reloadConfig
    )
    _ = try? await SolMacClient.send(request, requestTimeout: .seconds(1))
}

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "read or write solstone configuration.",
        subcommands: [Get.self, List.self, Set.self, Unset.self]
    )

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "get", abstract: "read one config value.")

        @Argument(help: "config key.")
        var key: String

        func run() async throws {
            guard AppConfig.knownKeys.contains(key) else {
                writeStructuredStderr(code: "config_unknown_key", message: "unknown config key: \(key)")
                throw ExitCode(SolMacExit.localValidation.rawValue)
            }

            print(renderValue(key: key, value: cfRead(key: key)))
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "list config values.")

        func run() async throws {
            for key in AppConfig.knownKeys {
                print("\(key)=\(renderValue(key: key, value: cfRead(key: key)))")
            }
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "set", abstract: "write one config value.")

        @Argument(help: "config key.")
        var key: String

        @Argument(help: "config value.")
        var value: String

        func run() async throws {
            guard AppConfig.knownKeys.contains(key) else {
                writeStderr("code: config_unknown_key, message: unknown config key: \(key)")
                throw ExitCode(SolMacExit.localValidation.rawValue)
            }

            guard scalarWritableKeys.contains(key) else {
                writeStderr("code: config_unsupported_in_cli, message: cli cannot write complex types in v1, hint: use the settings UI")
                throw ExitCode(SolMacExit.localValidation.rawValue)
            }

            let parsedValue: Any
            do {
                parsedValue = try parseScalar(key: key, value: value)
            } catch let error as ConfigParseError {
                writeStructuredStderr(code: "local_validation", message: "invalid value for \(key): \(error.reason)")
                throw ExitCode(SolMacExit.localValidation.rawValue)
            }

            guard cfWrite(key: key, value: parsedValue) else {
                writeStderr("code: cf_sync_failed, message: CFPreferencesAppSynchronize failed")
                throw ExitCode(SolMacExit.ipcError.rawValue)
            }

            await notifyReload()
        }
    }

    struct Unset: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "unset", abstract: "clear one config value.")

        @Argument(help: "config key.")
        var key: String

        func run() async throws {
            guard AppConfig.knownKeys.contains(key) else {
                writeStderr("code: config_unknown_key, message: unknown config key: \(key)")
                throw ExitCode(SolMacExit.localValidation.rawValue)
            }

            guard cfWrite(key: key, value: nil) else {
                writeStderr("code: cf_sync_failed, message: CFPreferencesAppSynchronize failed")
                throw ExitCode(SolMacExit.ipcError.rawValue)
            }

            await notifyReload()
        }
    }
}
