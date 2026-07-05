// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import CoreGraphics
import CoreText
import Foundation

public struct JournalIconWordInput {
    public let word: String
    public let baselineY: CGFloat

    public init(word: String, baselineY: CGFloat) {
        self.word = word
        self.baselineY = baselineY
    }
}

public struct JournalIconWordLayoutResult {
    public let paths: [CGPath]
    let combinedPath: CGPath
    let fontSizeInReferenceSpace: CGFloat
    let measuredWidths: [CGFloat]
}

@MainActor
public enum JournalIconWordLayout {
    static let referenceSide: CGFloat = 100
    static let startingFontSize: CGFloat = 12
    static let maximumWordWidth: CGFloat = 76
#if DEBUG
    static var forceFontUnavailableForTesting = false
#endif

    public static func outlinedPaths(
        for inputs: [JournalIconWordInput],
        tileSide: CGFloat
    ) -> JournalIconWordLayoutResult? {
        guard tileSide > 0, !inputs.isEmpty else { return nil }
#if DEBUG
        guard !forceFontUnavailableForTesting else { return nil }
#endif
        JournalMarkFont.register()
        guard fontIsAvailable(size: startingFontSize) else { return nil }

        let words = inputs.map {
            $0.word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard words.allSatisfy({ !$0.isEmpty }) else { return nil }

        let startingWidths = words.compactMap { measuredWidth(for: $0, fontSize: startingFontSize) }
        guard startingWidths.count == words.count,
              let longestWidth = startingWidths.max(),
              longestWidth > 0 else {
            return nil
        }

        let fontSize: CGFloat
        if longestWidth > maximumWordWidth {
            fontSize = startingFontSize * maximumWordWidth / longestWidth
        } else {
            fontSize = startingFontSize
        }
        guard let font = font(size: fontSize) else { return nil }

        var measuredWidths: [CGFloat] = []
        var paths: [CGPath] = []
        let combined = CGMutablePath()
        let scale = tileSide / referenceSide

        for (index, word) in words.enumerated() {
            let line = line(for: word, font: font)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            guard width > 0 else { return nil }
            measuredWidths.append(width)

            let pathInReferenceSpace = CGMutablePath()
            let lineOffsetX = (referenceSide - width) / 2
            guard appendGlyphs(
                from: line,
                to: pathInReferenceSpace,
                lineOffsetX: lineOffsetX,
                baselineY: inputs[index].baselineY
            ) else {
                return nil
            }

            var transform = CGAffineTransform(scaleX: scale, y: scale)
            guard let scaledPath = pathInReferenceSpace.copy(using: &transform) else {
                return nil
            }
            paths.append(scaledPath)
            combined.addPath(scaledPath)
        }

        return JournalIconWordLayoutResult(
            paths: paths,
            combinedPath: combined.copy()!,
            fontSizeInReferenceSpace: fontSize,
            measuredWidths: measuredWidths
        )
    }

    private static func fontIsAvailable(size: CGFloat) -> Bool {
        guard let probe = NSFont(name: JournalMarkFont.postScriptName, size: size) else {
            return false
        }
        return probe.fontName == JournalMarkFont.postScriptName
    }

    private static func font(size: CGFloat) -> CTFont? {
        let font = CTFontCreateWithName(JournalMarkFont.postScriptName as CFString, size, nil)
        guard CTFontCopyPostScriptName(font) as String == JournalMarkFont.postScriptName else {
            return nil
        }
        return font
    }

    private static func measuredWidth(for word: String, fontSize: CGFloat) -> CGFloat? {
        guard let font = font(size: fontSize) else { return nil }
        return CGFloat(CTLineGetTypographicBounds(line(for: word, font: font), nil, nil, nil))
    }

    private static func line(for word: String, font: CTFont) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: word, attributes: attributes))
    }

    private static func appendGlyphs(
        from line: CTLine,
        to path: CGMutablePath,
        lineOffsetX: CGFloat,
        baselineY: CGFloat
    ) -> Bool {
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        for run in runs {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let rawFont = attributes[kCTFontAttributeName] else {
                return false
            }
            let runFont = rawFont as! CTFont

            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)

            for index in 0..<count {
                guard let glyphPath = CTFontCreatePathForGlyph(runFont, glyphs[index], nil) else {
                    continue
                }
                let transform = CGAffineTransform(
                    a: 1,
                    b: 0,
                    c: 0,
                    d: -1,
                    tx: lineOffsetX + positions[index].x,
                    ty: baselineY - positions[index].y
                )
                path.addPath(glyphPath, transform: transform)
            }
        }
        return !path.isEmpty
    }
}
