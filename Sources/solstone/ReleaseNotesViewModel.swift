import Foundation

struct ReleaseNotesViewModel {
    enum Block {
        case heading(AttributedString)
        case listItem(AttributedString)
        case paragraph(AttributedString)
    }

    let blocks: [Block]?
    let wrapsInScrollView: Bool
    let onlineLinkLabel: String
    let onlineLinkURL: URL

    init(markdown: String) {
        self.init(markdown: markdown) { input in
            try AttributedString(markdown: input)
        }
    }

    init(markdown: String, parser: (String) throws -> AttributedString) {
        onlineLinkLabel = UpdatesCopy.releaseNotesOnlineLinkLabel
        onlineLinkURL = UpdatesCopy.releaseNotesOnlineURL

        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            blocks = nil
            wrapsInScrollView = false
            return
        }

        do {
            let attributed = try parser(markdown)
            let parsedBlocks = Self.blocks(from: attributed)
            blocks = parsedBlocks.isEmpty ? nil : parsedBlocks
            wrapsInScrollView = parsedBlocks.count > 3
        } catch {
            blocks = nil
            wrapsInScrollView = false
        }
    }

    static func containsOnlySupportedPresentationIntents(markdown: String) -> Bool {
        guard let attributed = try? AttributedString(markdown: markdown) else {
            return false
        }

        for (intent, _) in attributed.runs[\.presentationIntent] {
            guard let intent else { continue }
            for component in intent.components where !component.hasSupportedReleaseNotesKind {
                return false
            }
        }

        return true
    }

    private static func blocks(from attributed: AttributedString) -> [Block] {
        var groups: [BlockGroup] = []
        var currentGroup: BlockGroup?

        for (intent, range) in attributed.runs[\.presentationIntent] {
            guard let intent else { continue }

            let components = intent.components
            guard components.allSatisfy(\.hasSupportedReleaseNotesKind),
                  let classified = classify(components: components)
            else {
                return []
            }

            let slice = AttributedString(attributed[range])
            if var group = currentGroup, group.identity == classified.identity {
                group.text += slice
                currentGroup = group
            } else {
                if let currentGroup {
                    groups.append(currentGroup)
                }
                currentGroup = BlockGroup(kind: classified.kind, identity: classified.identity, text: slice)
            }
        }

        if let currentGroup {
            groups.append(currentGroup)
        }

        return groups.map(\.block)
    }

    private static func classify(components: [PresentationIntent.IntentType]) -> ClassifiedBlock? {
        if let component = components.first(where: \.isListItem) {
            return ClassifiedBlock(kind: .listItem, identity: component.identity)
        }

        if let component = components.first(where: \.isHeader) {
            return ClassifiedBlock(kind: .heading, identity: component.identity)
        }

        if let component = components.first(where: \.isParagraph) {
            return ClassifiedBlock(kind: .paragraph, identity: component.identity)
        }

        return nil
    }
}

private extension ReleaseNotesViewModel {
    enum BlockKind {
        case heading
        case listItem
        case paragraph
    }

    struct ClassifiedBlock {
        let kind: BlockKind
        let identity: Int
    }

    struct BlockGroup {
        let kind: BlockKind
        let identity: Int
        var text: AttributedString

        var block: Block {
            switch kind {
            case .heading:
                return .heading(text)
            case .listItem:
                return .listItem(text)
            case .paragraph:
                return .paragraph(text)
            }
        }
    }
}

private extension PresentationIntent.IntentType {
    var hasSupportedReleaseNotesKind: Bool {
        switch kind {
        case .header, .listItem, .paragraph, .unorderedList:
            return true
        default:
            return false
        }
    }

    var isHeader: Bool {
        if case .header = kind { return true }
        return false
    }

    var isListItem: Bool {
        if case .listItem = kind { return true }
        return false
    }

    var isParagraph: Bool {
        if case .paragraph = kind { return true }
        return false
    }
}
