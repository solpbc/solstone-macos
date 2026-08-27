import Foundation
import Testing

// Covers retired-asset naming only. Source->raster freshness and palette are
// gated separately by `make check-brand-assets-fresh` (scripts/check-brand-assets-fresh.sh),
// wired into `make ci`.
@Suite("Brand asset hygiene")
struct BrandAssetHygieneTests {
    @Test func halfSunAssetAndBrandSyncNeedleAreGone() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        // Assembled so a retired-asset grep sweep finds no live reference.
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
