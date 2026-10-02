import SwiftUI

public struct AXStateCompanion: View {
    /// The defaults key a test harness sets to publish state companions. Without it a companion
    /// keeps its footprint but leaves the accessibility tree, so VoiceOver never reads its machine
    /// id and token. `-solstone.ax.stateCompanions YES` on the command line sets it too.
    nonisolated public static let publishKey = "solstone.ax.stateCompanions"

    /// Read once, at first render: a process started without the key never publishes.
    @MainActor public static var isPublished = published(in: .standard)

    nonisolated public static func published(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: publishKey)
    }

    public let id: String
    public let value: String

    public init(id: String, value: String) {
        self.id = id
        self.value = value
    }

    public var body: some View {
        if Self.isPublished {
            Text(value)
                .font(.system(size: 1))
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .clipped()
                .accessibilityIdentifier(id)
                .accessibilityLabel(id)
                .accessibilityValue(value)
        } else {
            // Same footprint either way, so the release gate drives the layout an owner sees.
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        }
    }
}

public func axEnabledString(_ enabled: Bool) -> String {
    enabled ? "enabled" : "disabled"
}

public func axPercentString(_ fraction: Double) -> String {
    let percent = Int((fraction * 100).rounded())
    return String(min(max(percent, 0), 100))
}

public func axDownloadPercentString(receivedBytes: UInt64, totalBytes: UInt64?) -> String {
    guard let totalBytes, totalBytes > 0 else { return "0" }
    return axPercentString(Double(receivedBytes) / Double(totalBytes))
}
