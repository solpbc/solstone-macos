import Foundation
import Testing
@testable import solstone

@Suite("ReleaseNotesViewModel")
struct ReleaseNotesViewModelTests {
    @Test func live130FixtureProducesExpectedBlocks() throws {
        let model = ReleaseNotesViewModel(markdown: try fixture())
        let blocks = try #require(model.blocks)

        #expect(blocks.map(blockKind) == [
            "heading", "listItem", "listItem", "listItem",
            "heading", "listItem", "listItem", "listItem",
            "heading", "listItem", "listItem", "listItem"
        ])
        #expect(plainText(blocks[0]) == "Added")
        #expect(!plainText(blocks[0]).contains("###"))
        #expect(plainText(blocks[1]).hasPrefix("you can now run sol's on-screen analysis"))
        #expect(!plainText(blocks[1]).contains("- "))
        #expect(model.blocks != nil)
    }

    @Test func inlineStylingPreservedInListItem() throws {
        let model = ReleaseNotesViewModel(markdown: "- before **bold** middle [label](https://example.com) after")
        let blocks = try #require(model.blocks)
        guard case .listItem(let text) = try #require(blocks.first) else {
            Issue.record("expected a list item block")
            return
        }

        let boldRun = try #require(text.runs.first { run in
            String(text[run.range].characters) == "bold"
        })
        #expect(boldRun.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)

        let linkRun = try #require(text.runs.first { run in
            String(text[run.range].characters) == "label"
        })
        #expect(linkRun.link == URL(string: "https://example.com"))
    }

    @Test func emptyInputFallsBack() {
        #expect(ReleaseNotesViewModel(markdown: "").blocks == nil)
        #expect(ReleaseNotesViewModel(markdown: "   \n  ").blocks == nil)
    }

    @Test func parseFailureFallsBack() {
        // Foundation's markdown parser is lenient for malformed strings, so inject a throwing parser to cover the catch path.
        let model = ReleaseNotesViewModel(markdown: "### ok") { _ in
            throw TestParseError.failure
        }

        #expect(model.blocks == nil)
    }

    @Test func zeroBlocksFallsBack() {
        let model = ReleaseNotesViewModel(markdown: "plain") { _ in
            AttributedString("plain")
        }

        #expect(model.blocks == nil)
    }

    @Test func unsupportedIntentFallsBack() {
        #expect(ReleaseNotesViewModel(markdown: "1. one").blocks == nil)
        #expect(ReleaseNotesViewModel(markdown: "> quote").blocks == nil)
        #expect(ReleaseNotesViewModel(markdown: "```swift\nlet x = 1\n```").blocks == nil)
    }

    @Test func live130FixtureContainsNoUnsupportedIntents() throws {
        #expect(ReleaseNotesViewModel.containsOnlySupportedPresentationIntents(markdown: try fixture()))
    }

    @Test func wrapsOnlyWhenMoreThanThreeBlocks() throws {
        #expect(ReleaseNotesViewModel(markdown: try fixture()).wrapsInScrollView)

        let fortyBlocks = (1...40).map { "- item \($0)" }.joined(separator: "\n")
        #expect(ReleaseNotesViewModel(markdown: fortyBlocks).wrapsInScrollView)

        #expect(!ReleaseNotesViewModel(markdown: "### one").wrapsInScrollView)
    }

    @Test func onlineLinkUsesUpdatesCopyConstants() {
        let model = ReleaseNotesViewModel(markdown: "### one")

        #expect(model.onlineLinkLabel == UpdatesCopy.releaseNotesOnlineLinkLabel)
        #expect(model.onlineLinkURL == UpdatesCopy.releaseNotesOnlineURL)
        #expect(model.onlineLinkURL == URL(string: "https://solstone.app/releases/macos")!)
    }

    private enum TestParseError: Error {
        case failure
    }

    private func fixture() throws -> String {
        let url = try #require(Bundle.module.url(forResource: "release-notes-1.3.0", withExtension: "md", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func blockKind(_ block: ReleaseNotesViewModel.Block) -> String {
        switch block {
        case .heading:
            return "heading"
        case .listItem:
            return "listItem"
        case .paragraph:
            return "paragraph"
        }
    }

    private func plainText(_ block: ReleaseNotesViewModel.Block) -> String {
        switch block {
        case .heading(let text), .listItem(let text), .paragraph(let text):
            return String(text.characters)
        }
    }
}
