import SwiftUI

public struct AXStateCompanion: View {
    public let id: String
    public let value: String

    public init(id: String, value: String) {
        self.id = id
        self.value = value
    }

    public var body: some View {
        Text(value)
            .font(.system(size: 1))
            .frame(width: 1, height: 1)
            .opacity(0.001)
            .clipped()
            .accessibilityIdentifier(id)
            .accessibilityLabel(id)
            .accessibilityValue(value)
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
