import Foundation
import Testing

@Suite("Brand asset hygiene")
struct BrandAssetHygieneTests {
    @Test func halfSunAssetAndBrandSyncNeedleAreGone() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        // Assembled so a retired-asset grep sweep finds no live reference.
        // Makefile:217 mentions the bare word "half"; that comment is intentional
        // and is not matched (the assertion is on the full needle, not the bare word).
        let needle = "sol-ring-icon-" + "half"

        let retiredSVG = repoRoot
            .appendingPathComponent("assets")
            .appendingPathComponent(needle + ".svg")
        #expect(!FileManager.default.fileExists(atPath: retiredSVG.path))

        let makefile = try String(
            contentsOf: repoRoot.appendingPathComponent("Makefile"),
            encoding: .utf8
        )
        #expect(!makefile.contains(needle))

        for relative in ["assets", "Sources/solstone/Resources"] {
            let directory = repoRoot.appendingPathComponent(relative)
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: nil
            )
            let urls = enumerator?.compactMap { $0 as? URL } ?? []
            #expect(enumerator != nil)
            for url in urls {
                #expect(!url.lastPathComponent.localizedCaseInsensitiveContains("half"))
            }
        }
    }
}
