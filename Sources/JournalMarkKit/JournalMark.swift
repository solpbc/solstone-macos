// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SwiftUI

public nonisolated struct JournalMark: Codable, Equatable, Sendable {
    public let icon1: Icon
    public let icon2: Icon
    public let words: [String]

    public enum CodingKeys: String, CodingKey {
        case icon1
        case icon2
        case words
    }

    public nonisolated struct Icon: Codable, Equatable, Sendable {
        public let name: String
        public let color: MarkColor
        public let rot: Int
        public let svg: String

        public init(name: String, color: MarkColor, rot: Int, svg: String) {
            self.name = name
            self.color = color
            self.rot = rot
            self.svg = svg
        }
    }

    public nonisolated struct MarkColor: Codable, Equatable, Sendable {
        public let hex: String

        public init(hex: String) {
            self.hex = hex
        }
    }

    public init(icon1: Icon, icon2: Icon, words: [String]) {
        self.icon1 = icon1
        self.icon2 = icon2
        self.words = words
    }

    public static func validate(_ mark: JournalMark) -> JournalMark? {
        guard mark.words.count == 2,
              mark.words.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Self.isValid(mark.icon1),
              Self.isValid(mark.icon2)
        else {
            return nil
        }
        return mark
    }

    private static func isValid(_ icon: Icon) -> Bool {
        guard icon.rot == 0 || icon.rot == 45,
              Self.isValidHexColor(icon.color.hex),
              !icon.svg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let path = GlyphParser.parse(innerMarkup: icon.svg),
              !path.isEmpty
        else {
            return false
        }
        return true
    }

    private static func isValidHexColor(_ hex: String) -> Bool {
        guard hex.count == 7, hex.first == "#" else { return false }
        return hex.dropFirst().allSatisfy { character in
            character.isNumber || ("a"..."f").contains(character.lowercased())
        }
    }
}

#if DEBUG
extension JournalMark {
    public static let uiTestSample = JournalMark(
        icon1: Icon(
            name: "bug",
            color: MarkColor(hex: "#f59e0b"),
            rot: 0,
            svg: #"<path d="M12 20v-9" /> <path d="M14 7a4 4 0 0 1 4 4v3a6 6 0 0 1-12 0v-3a4 4 0 0 1 4-4z" /> <path d="M14.12 3.88 16 2" /> <path d="M21 21a4 4 0 0 0-3.81-4" /> <path d="M21 5a4 4 0 0 1-3.55 3.97" /> <path d="M22 13h-4" /> <path d="M3 21a4 4 0 0 1 3.81-4" /> <path d="M3 5a4 4 0 0 0 3.55 3.97" /> <path d="M6 13H2" /> <path d="m8 2 1.88 1.88" /> <path d="M9 7.13V6a3 3 0 1 1 6 0v1.13" />"#
        ),
        icon2: Icon(
            name: "gem",
            color: MarkColor(hex: "#84cc16"),
            rot: 45,
            svg: #"<path d="M10.5 3 8 9l4 13 4-13-2.5-6" /> <path d="M17 3a2 2 0 0 1 1.6.8l3 4a2 2 0 0 1 .013 2.382l-7.99 10.986a2 2 0 0 1-3.247 0l-7.99-10.986A2 2 0 0 1 2.4 7.8l2.998-3.997A2 2 0 0 1 7 3z" /> <path d="M2 9h20" />"#
        ),
        words: ["afoot", "unfixed"]
    )
}
#endif

public struct JournalMarkView: View {
    let mark: JournalMark
    var isConfirmed = false

    public init(mark: JournalMark, isConfirmed: Bool = false) {
        self.mark = mark
        self.isConfirmed = isConfirmed
    }

    public var body: some View {
        VStack(spacing: MarkGeometry.verticalGap) {
            HStack(spacing: MarkGeometry.iconGap) {
                JournalMarkIconChip(icon: self.mark.icon1)
                JournalMarkIconChip(icon: self.mark.icon2)
            }

            Text(self.mark.words.joined(separator: " · "))
                .font(JournalMarkFont.isRegistered ? .custom("Comfortaa-Bold", size: MarkGeometry.wordFontSize, relativeTo: .headline) : .system(size: MarkGeometry.wordFontSize, weight: .bold, design: .rounded))
                .foregroundStyle(MarkGeometry.wordColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if self.isConfirmed {
                Text(UICopy.JOURNAL_MARK_CONFIRMED_LINE)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MarkGeometry.confirmationColor)
            }
        }
        .padding(.horizontal, MarkGeometry.cardHorizontalPadding)
        .padding(.vertical, MarkGeometry.cardVerticalPadding)
        .background(MarkGeometry.cardFill, in: RoundedRectangle(cornerRadius: MarkGeometry.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MarkGeometry.cardRadius, style: .continuous)
                .stroke(self.isConfirmed ? MarkGeometry.confirmedBorder : MarkGeometry.cardBorder, lineWidth: self.isConfirmed ? 2 : 1)
        }
        .shadow(color: self.isConfirmed ? MarkGeometry.confirmedBorder.opacity(0.35) : .clear, radius: 10)
        .accessibilityElement(children: .combine)
    }
}

private struct JournalMarkIconChip: View {
    let icon: JournalMark.Icon

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MarkGeometry.chipRadius, style: .continuous)
                .fill(MarkGeometry.color(hex: self.icon.color.hex).opacity(MarkGeometry.iconFillOpacity))
                .overlay {
                    RoundedRectangle(cornerRadius: MarkGeometry.chipRadius, style: .continuous)
                        .stroke(MarkGeometry.chipBorder, lineWidth: MarkGeometry.chipBorderWidth)
                }

            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height) * MarkGeometry.glyphScale
                let rect = CGRect(
                    x: (proxy.size.width - side) / 2,
                    y: (proxy.size.height - side) / 2,
                    width: side,
                    height: side
                )
                GlyphShape(svg: self.icon.svg)
                    .stroke(
                        MarkGeometry.color(hex: self.icon.color.hex),
                        style: StrokeStyle(
                            lineWidth: MarkGeometry.glyphLineWidth(for: rect),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .frame(width: MarkGeometry.size, height: MarkGeometry.size)
        .rotationEffect(.degrees(self.icon.rot == 45 ? 45 : 0))
        .accessibilityLabel(self.icon.name)
    }
}

private struct GlyphShape: Shape {
    let svg: String

    func path(in rect: CGRect) -> Path {
        GlyphParser.parse(innerMarkup: self.svg, in: rect) ?? Path()
    }
}

enum MarkGeometry {
    static let size: CGFloat = 64
    static let chipRadius: CGFloat = size * 0.25
    static let chipBorderWidth: CGFloat = 2
    static let iconFillOpacity = 0.12
    static let glyphScale: CGFloat = 0.58
    static let iconGap: CGFloat = size * 0.23
    static let verticalGap: CGFloat = 10
    static let wordFontSize: CGFloat = 19
    static let cardRadius: CGFloat = 12
    static let cardHorizontalPadding: CGFloat = 22
    static let cardVerticalPadding: CGFloat = 18

    static let cardFill = Self.color(hex: "#fffdf9")
    static let cardBorder = Self.color(hex: "#e7d8c6")
    static let chipBorder = Self.color(hex: "#e7d8c6")
    static let wordColor = Self.color(hex: "#c2b9a6")
    static let confirmationColor = Self.color(hex: "#166534")
    static let confirmedBorder = Self.color(hex: "#cfe3d3")

    static func glyphLineWidth(for rect: CGRect) -> CGFloat {
        max(rect.width / 24 * 2, 1)
    }

    static func color(hex: String) -> Color {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6,
              let value = Int(trimmed, radix: 16)
        else {
            return .primary
        }
        return Color(
            red: Double((value >> 16) & 0xff) / 255.0,
            green: Double((value >> 8) & 0xff) / 255.0,
            blue: Double(value & 0xff) / 255.0
        )
    }
}

nonisolated enum GlyphParser {
    static func parse(innerMarkup: String, in rect: CGRect = CGRect(x: 0, y: 0, width: 24, height: 24)) -> Path? {
        guard let elements = SVGElementTokenizer.elements(from: innerMarkup), !elements.isEmpty else {
            return nil
        }

        var path = Path()
        for element in elements {
            guard let subpath = Self.path(for: element) else {
                return nil
            }
            path.addPath(subpath)
        }

        let transform = CGAffineTransform(
            a: rect.width / 24,
            b: 0,
            c: 0,
            d: rect.height / 24,
            tx: rect.minX,
            ty: rect.minY
        )
        return path.applying(transform)
    }

    private static func path(for element: SVGElement) -> Path? {
        switch element.name {
        case "path":
            guard element.attributes.keys.allSatisfy({ $0 == "d" }),
                  let d = element.attributes["d"],
                  var parser = PathDataParser(d: d) else {
                return nil
            }
            return parser.parse()
        case "circle":
            guard element.attributes.keys.allSatisfy({ ["cx", "cy", "r"].contains($0) }),
                  let cx = element.double("cx"),
                  let cy = element.double("cy"),
                  let r = element.double("r"),
                  r >= 0 else {
                return nil
            }
            var path = Path()
            path.addEllipse(in: CGRect(x: CGFloat(cx - r), y: CGFloat(cy - r), width: CGFloat(r * 2), height: CGFloat(r * 2)))
            return path
        case "ellipse":
            guard element.attributes.keys.allSatisfy({ ["cx", "cy", "rx", "ry"].contains($0) }),
                  let cx = element.double("cx"),
                  let cy = element.double("cy"),
                  let rx = element.double("rx"),
                  let ry = element.double("ry"),
                  rx >= 0,
                  ry >= 0 else {
                return nil
            }
            var path = Path()
            path.addEllipse(in: CGRect(x: CGFloat(cx - rx), y: CGFloat(cy - ry), width: CGFloat(rx * 2), height: CGFloat(ry * 2)))
            return path
        case "rect":
            guard element.attributes.keys.allSatisfy({ ["x", "y", "width", "height", "rx", "ry"].contains($0) }),
                  let width = element.double("width"),
                  let height = element.double("height"),
                  width >= 0,
                  height >= 0 else {
                return nil
            }
            let x = element.double("x") ?? 0
            let y = element.double("y") ?? 0
            let rx = element.double("rx") ?? element.double("ry") ?? 0
            let ry = element.double("ry") ?? element.double("rx") ?? 0
            var path = Path()
            if rx > 0 || ry > 0 {
                path.addRoundedRect(
                    in: CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height)),
                    cornerSize: CGSize(width: CGFloat(rx), height: CGFloat(ry)),
                    style: .continuous
                )
            } else {
                path.addRect(CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height)))
            }
            return path
        default:
            return nil
        }
    }
}

private nonisolated struct SVGElement: Equatable {
    let name: String
    let attributes: [String: String]

    func double(_ name: String) -> Double? {
        guard let raw = attributes[name] else { return nil }
        return SVGNumberTokenizer(raw).singleNumber()
    }
}

private nonisolated enum SVGElementTokenizer {
    static func elements(from markup: String) -> [SVGElement]? {
        var elements: [SVGElement] = []
        var index = markup.startIndex
        while index < markup.endIndex {
            guard let open = markup[index...].firstIndex(of: "<") else {
                return markup[index...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? elements : nil
            }
            guard markup[index..<open].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            guard let close = markup[open...].firstIndex(of: ">") else {
                return nil
            }
            let contentStart = markup.index(after: open)
            var content = String(markup[contentStart..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
            if content.hasPrefix("!--") {
                index = markup.index(after: close)
                continue
            }
            if content.hasPrefix("/") {
                return nil
            }
            if content.hasSuffix("/") {
                content.removeLast()
                content = content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let element = Self.element(from: content) else {
                return nil
            }
            elements.append(element)
            index = markup.index(after: close)
        }
        return elements
    }

    private static func element(from content: String) -> SVGElement? {
        var index = content.startIndex
        guard let name = Self.readName(in: content, index: &index) else {
            return nil
        }
        var attributes: [String: String] = [:]
        while index < content.endIndex {
            Self.skipSpaces(in: content, index: &index)
            guard index < content.endIndex else { break }
            guard let attributeName = Self.readName(in: content, index: &index) else {
                return nil
            }
            Self.skipSpaces(in: content, index: &index)
            guard index < content.endIndex, content[index] == "=" else {
                return nil
            }
            index = content.index(after: index)
            Self.skipSpaces(in: content, index: &index)
            guard index < content.endIndex, content[index] == "\"" || content[index] == "'" else {
                return nil
            }
            let quote = content[index]
            index = content.index(after: index)
            let valueStart = index
            guard let valueEnd = content[index...].firstIndex(of: quote) else {
                return nil
            }
            attributes[attributeName] = String(content[valueStart..<valueEnd])
            index = content.index(after: valueEnd)
        }
        return SVGElement(name: name.lowercased(), attributes: attributes)
    }

    private static func readName(in string: String, index: inout String.Index) -> String? {
        let start = index
        while index < string.endIndex {
            let char = string[index]
            guard char.isLetter || char.isNumber || char == "-" || char == "_" || char == ":" else {
                break
            }
            index = string.index(after: index)
        }
        guard index > start else { return nil }
        return String(string[start..<index])
    }

    private static func skipSpaces(in string: String, index: inout String.Index) {
        while index < string.endIndex, string[index].isWhitespace {
            index = string.index(after: index)
        }
    }
}

private nonisolated enum PathToken: Equatable {
    case command(Character)
    case number(Double)
}

private nonisolated struct SVGNumberTokenizer {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    func tokens() -> [PathToken]? {
        var tokens: [PathToken] = []
        var index = text.startIndex
        while index < text.endIndex {
            Self.skipSeparators(in: text, index: &index)
            guard index < text.endIndex else { break }
            let char = text[index]
            if char.isLetter {
                tokens.append(.command(char))
                index = text.index(after: index)
                continue
            }
            guard let number = Self.readNumber(in: text, index: &index) else {
                return nil
            }
            tokens.append(.number(number))
        }
        return tokens
    }

    func singleNumber() -> Double? {
        guard let tokens = self.tokens(),
              tokens.count == 1,
              case .number(let value) = tokens[0] else {
            return nil
        }
        return value
    }

    private static func skipSeparators(in string: String, index: inout String.Index) {
        while index < string.endIndex {
            let char = string[index]
            guard char.isWhitespace || char == "," else { return }
            index = string.index(after: index)
        }
    }

    private static func readNumber(in string: String, index: inout String.Index) -> Double? {
        let start = index
        if string[index] == "+" || string[index] == "-" {
            index = string.index(after: index)
        }

        var sawDigit = false
        while index < string.endIndex, string[index].isNumber {
            sawDigit = true
            index = string.index(after: index)
        }

        if index < string.endIndex, string[index] == "." {
            index = string.index(after: index)
            while index < string.endIndex, string[index].isNumber {
                sawDigit = true
                index = string.index(after: index)
            }
        }

        guard sawDigit else {
            return nil
        }

        if index < string.endIndex, string[index] == "e" || string[index] == "E" {
            let exponentStart = index
            var exponentIndex = string.index(after: index)
            if exponentIndex < string.endIndex, string[exponentIndex] == "+" || string[exponentIndex] == "-" {
                exponentIndex = string.index(after: exponentIndex)
            }
            let digitStart = exponentIndex
            while exponentIndex < string.endIndex, string[exponentIndex].isNumber {
                exponentIndex = string.index(after: exponentIndex)
            }
            guard exponentIndex > digitStart else {
                index = exponentStart
                return Double(string[start..<index])
            }
            index = exponentIndex
        }

        return Double(string[start..<index])
    }
}

private nonisolated struct PathDataParser {
    let tokens: [PathToken]
    var index = 0
    var path = Path()
    var current = CGPoint.zero
    var subpathStart = CGPoint.zero
    var previousCommand: Character?
    var previousCubicControl: CGPoint?
    var previousQuadControl: CGPoint?

    init?(d: String) {
        guard let tokens = SVGNumberTokenizer(d).tokens() else { return nil }
        self.tokens = tokens
    }

    mutating func parse() -> Path? {
        var command: Character?
        while index < tokens.count {
            if case .command(let nextCommand) = tokens[index] {
                command = nextCommand
                index += 1
            } else if command == nil {
                return nil
            }
            guard let activeCommand = command else { return nil }
            guard Self.isSupported(activeCommand) else { return nil }
            if activeCommand == "Z" || activeCommand == "z" {
                path.closeSubpath()
                current = subpathStart
                resetControls(after: activeCommand)
                previousCommand = activeCommand
                command = nil
                continue
            }
            guard parse(activeCommand, nextCommand: &command) else {
                return nil
            }
        }
        return path
    }

    private static func isSupported(_ command: Character) -> Bool {
        "MmLlHhVvCcSsQqTtAaZz".contains(command)
    }

    private mutating func parse(_ command: Character, nextCommand: inout Character?) -> Bool {
        switch command {
        case "M", "m":
            guard let first = readPoint(relative: command == "m") else { return false }
            path.move(to: first)
            current = first
            subpathStart = first
            resetControls(after: command)
            previousCommand = command
            nextCommand = command == "m" ? "l" : "L"
            while hasNumberAhead {
                guard let point = readPoint(relative: command == "m") else { return false }
                path.addLine(to: point)
                current = point
                previousCommand = nextCommand
            }
            return true
        case "L", "l":
            var parsed = false
            while hasNumberAhead {
                guard let point = readPoint(relative: command == "l") else { return false }
                path.addLine(to: point)
                current = point
                parsed = true
                resetControls(after: command)
                previousCommand = command
            }
            return parsed
        case "H", "h":
            var parsed = false
            while hasNumberAhead {
                guard let x = readNumber() else { return false }
                let point = CGPoint(x: command == "h" ? current.x + CGFloat(x) : CGFloat(x), y: current.y)
                path.addLine(to: point)
                current = point
                parsed = true
                resetControls(after: command)
                previousCommand = command
            }
            return parsed
        case "V", "v":
            var parsed = false
            while hasNumberAhead {
                guard let y = readNumber() else { return false }
                let point = CGPoint(x: current.x, y: command == "v" ? current.y + CGFloat(y) : CGFloat(y))
                path.addLine(to: point)
                current = point
                parsed = true
                resetControls(after: command)
                previousCommand = command
            }
            return parsed
        case "C", "c":
            var parsed = false
            while hasNumberAhead {
                guard let c1 = readPoint(relative: command == "c"),
                      let c2 = readPoint(relative: command == "c"),
                      let end = readPoint(relative: command == "c") else { return false }
                path.addCurve(to: end, control1: c1, control2: c2)
                previousCubicControl = c2
                previousQuadControl = nil
                current = end
                parsed = true
                resetControls(after: command)
                previousCommand = command
            }
            return parsed
        case "S", "s":
            var parsed = false
            while hasNumberAhead {
                let reflected = reflectedCubicControl()
                guard let c2 = readPoint(relative: command == "s"),
                      let end = readPoint(relative: command == "s") else { return false }
                path.addCurve(to: end, control1: reflected, control2: c2)
                previousCubicControl = c2
                previousQuadControl = nil
                current = end
                parsed = true
                resetControls(after: command)
                previousCommand = command
            }
            return parsed
        case "Q", "q":
            var parsed = false
            while hasNumberAhead {
                guard let control = readPoint(relative: command == "q"),
                      let end = readPoint(relative: command == "q") else { return false }
                path.addQuadCurve(to: end, control: control)
                previousQuadControl = control
                previousCubicControl = nil
                current = end
                parsed = true
                resetControls(after: command)
                previousCommand = command
            }
            return parsed
        case "T", "t":
            var parsed = false
            while hasNumberAhead {
                let control = reflectedQuadControl()
                guard let end = readPoint(relative: command == "t") else { return false }
                path.addQuadCurve(to: end, control: control)
                previousQuadControl = control
                previousCubicControl = nil
                current = end
                parsed = true
                resetControls(after: command)
                previousCommand = command
            }
            return parsed
        case "A", "a":
            var parsed = false
            while hasNumberAhead {
                guard let rx = readNumber(),
                      let ry = readNumber(),
                      let rotation = readNumber(),
                      let largeArc = readNumber(),
                      let sweep = readNumber(),
                      let end = readPoint(relative: command == "a") else { return false }
                addArc(
                    from: current,
                    to: end,
                    rx: rx,
                    ry: ry,
                    xAxisRotation: rotation,
                    largeArc: largeArc != 0,
                    sweep: sweep != 0
                )
                current = end
                previousCubicControl = nil
                previousQuadControl = nil
                parsed = true
                resetControls(after: command)
                previousCommand = command
            }
            return parsed
        default:
            return false
        }
    }

    private var hasNumberAhead: Bool {
        guard index < tokens.count else { return false }
        if case .number = tokens[index] { return true }
        return false
    }

    private mutating func readNumber() -> Double? {
        guard index < tokens.count,
              case .number(let value) = tokens[index] else {
            return nil
        }
        index += 1
        return value
    }

    private mutating func readPoint(relative: Bool) -> CGPoint? {
        guard let x = readNumber(),
              let y = readNumber() else {
            return nil
        }
        if relative {
            return CGPoint(x: current.x + CGFloat(x), y: current.y + CGFloat(y))
        }
        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }

    private func reflectedCubicControl() -> CGPoint {
        guard let previousCommand,
              "CcSs".contains(previousCommand),
              let previousCubicControl else {
            return current
        }
        return CGPoint(x: current.x * 2 - previousCubicControl.x, y: current.y * 2 - previousCubicControl.y)
    }

    private func reflectedQuadControl() -> CGPoint {
        guard let previousCommand,
              "QqTt".contains(previousCommand),
              let previousQuadControl else {
            return current
        }
        return CGPoint(x: current.x * 2 - previousQuadControl.x, y: current.y * 2 - previousQuadControl.y)
    }

    private mutating func resetControls(after command: Character) {
        if !"CcSs".contains(command) {
            previousCubicControl = nil
        }
        if !"QqTt".contains(command) {
            previousQuadControl = nil
        }
    }

    private mutating func addArc(
        from start: CGPoint,
        to end: CGPoint,
        rx rawRX: Double,
        ry rawRY: Double,
        xAxisRotation: Double,
        largeArc: Bool,
        sweep: Bool
    ) {
        var rx = abs(rawRX)
        var ry = abs(rawRY)
        guard rx > 0, ry > 0, start != end else {
            path.addLine(to: end)
            return
        }

        let phi = xAxisRotation * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx = (Double(start.x) - Double(end.x)) / 2
        let dy = (Double(start.y) - Double(end.y)) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        let lambda = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry)
        if lambda > 1 {
            let scale = sqrt(lambda)
            rx *= scale
            ry *= scale
        }

        let rx2 = rx * rx
        let ry2 = ry * ry
        let x1p2 = x1p * x1p
        let y1p2 = y1p * y1p
        let denominator = rx2 * y1p2 + ry2 * x1p2
        guard denominator > 0 else {
            path.addLine(to: end)
            return
        }
        let numerator = max(rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2, 0)
        let coefficient = (largeArc == sweep ? -1.0 : 1.0) * sqrt(numerator / denominator)
        let cxp = coefficient * (rx * y1p / ry)
        let cyp = coefficient * (-ry * x1p / rx)

        let cx = cosPhi * cxp - sinPhi * cyp + (Double(start.x) + Double(end.x)) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (Double(start.y) + Double(end.y)) / 2
        let theta1 = Self.angle(ux: 1, uy: 0, vx: (x1p - cxp) / rx, vy: (y1p - cyp) / ry)
        var delta = Self.angle(
            ux: (x1p - cxp) / rx,
            uy: (y1p - cyp) / ry,
            vx: (-x1p - cxp) / rx,
            vy: (-y1p - cyp) / ry
        )
        if !sweep && delta > 0 {
            delta -= 2 * .pi
        } else if sweep && delta < 0 {
            delta += 2 * .pi
        }

        let segments = max(Int(ceil(abs(delta) / (.pi / 2))), 1)
        let segmentDelta = delta / Double(segments)
        for segment in 0..<segments {
            let startAngle = theta1 + Double(segment) * segmentDelta
            let endAngle = startAngle + segmentDelta
            addArcSegment(
                center: CGPoint(x: CGFloat(cx), y: CGFloat(cy)),
                rx: rx,
                ry: ry,
                phi: phi,
                startAngle: startAngle,
                endAngle: endAngle
            )
        }
    }

    private mutating func addArcSegment(
        center: CGPoint,
        rx: Double,
        ry: Double,
        phi: Double,
        startAngle: Double,
        endAngle: Double
    ) {
        let alpha = 4.0 / 3.0 * tan((endAngle - startAngle) / 4.0)
        let p1 = CGPoint(x: CGFloat(cos(startAngle)), y: CGFloat(sin(startAngle)))
        let p2 = CGPoint(x: CGFloat(cos(endAngle)), y: CGFloat(sin(endAngle)))
        let c1 = CGPoint(
            x: CGFloat(Double(p1.x) - alpha * Double(p1.y)),
            y: CGFloat(Double(p1.y) + alpha * Double(p1.x))
        )
        let c2 = CGPoint(
            x: CGFloat(Double(p2.x) + alpha * Double(p2.y)),
            y: CGFloat(Double(p2.y) - alpha * Double(p2.x))
        )

        path.addCurve(
            to: Self.arcPoint(p2, center: center, rx: rx, ry: ry, phi: phi),
            control1: Self.arcPoint(c1, center: center, rx: rx, ry: ry, phi: phi),
            control2: Self.arcPoint(c2, center: center, rx: rx, ry: ry, phi: phi)
        )
    }

    private static func arcPoint(_ point: CGPoint, center: CGPoint, rx: Double, ry: Double, phi: Double) -> CGPoint {
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let x = rx * Double(point.x)
        let y = ry * Double(point.y)
        return CGPoint(
            x: CGFloat(Double(center.x) + cosPhi * x - sinPhi * y),
            y: CGFloat(Double(center.y) + sinPhi * x + cosPhi * y)
        )
    }

    private static func angle(ux: Double, uy: Double, vx: Double, vy: Double) -> Double {
        let dot = ux * vx + uy * vy
        let length = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
        guard length > 0 else { return 0 }
        let clamped = min(max(dot / length, -1), 1)
        let sign = ux * vy - uy * vx < 0 ? -1.0 : 1.0
        return sign * acos(clamped)
    }
}

#if DEBUG
#Preview {
    JournalMarkView(mark: .uiTestSample, isConfirmed: true)
        .padding()
}
#endif
