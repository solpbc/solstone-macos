import Foundation

enum SolVersionParser {
    static func parse(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let pattern = #"\d+\.\d+\.\d+"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
            let range = Range(match.range, in: trimmed)
        else { return nil }
        return String(trimmed[range])
    }
}
