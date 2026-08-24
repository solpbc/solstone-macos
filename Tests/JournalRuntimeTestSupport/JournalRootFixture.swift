import Foundation

public final class JournalRootFixture {
    public let rootURL: URL
    public let configURL: URL

    public init() throws {
        rootURL = URL(fileURLWithPath: "/var/tmp", isDirectory: true)
            .appendingPathComponent("journal-root-fixture-\(UUID().uuidString)", isDirectory: true)
        configURL = rootURL
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("journal.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    public func writeConfig(_ text: String) throws {
        try Data(text.utf8).write(to: configURL)
    }

    public func removeConfig() throws {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        try FileManager.default.removeItem(at: configURL)
    }

    public func makeConfigUnreadable() throws -> Int {
        let originalPermissions = try configPermissions()
        try setConfigPermissions(0)
        return originalPermissions
    }

    public func restoreConfigPermissions(_ permissions: Int) throws {
        try setConfigPermissions(permissions)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func configPermissions() throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: configURL.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return permissions.intValue & 0o7777
    }

    private func setConfigPermissions(_ permissions: Int) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: configURL.path
        )
    }
}
