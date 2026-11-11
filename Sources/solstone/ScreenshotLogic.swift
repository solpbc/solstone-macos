// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation

// MARK: - span

/// How far back the owner chose. The starts match the calendar source.
enum ScreenshotSpan: String, Codable, CaseIterable, Equatable, Sendable {
    case last30Days
    case last6Months
    case lastYear
    case everything
    case fromToday

    var label: String {
        switch self {
        case .last30Days: return ScreenshotCopy.last30Days
        case .last6Months: return ScreenshotCopy.last6Months
        case .lastYear: return ScreenshotCopy.lastYear
        case .everything: return ScreenshotCopy.allOfIt
        case .fromToday: return ScreenshotCopy.nothingFromBeforeToday
        }
    }

    var fromToday: Bool { self == .fromToday }

    func start(now: Date, timeZone: TimeZone) -> Date {
        let calendar = ScreenshotCalendar.gregorian(in: timeZone)
        let today = calendar.startOfDay(for: now)
        switch self {
        case .last30Days:
            return calendar.date(byAdding: .day, value: -30, to: today) ?? today
        case .last6Months:
            return calendar.date(byAdding: .month, value: -6, to: today) ?? today
        case .lastYear:
            return calendar.date(byAdding: .year, value: -1, to: today) ?? today
        case .everything:
            return calendar.date(from: DateComponents(year: 1900, month: 1, day: 1)) ?? today
        case .fromToday:
            return today
        }
    }
}

enum ScreenshotCalendar {
    static func gregorian(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar
    }
}

// MARK: - the moment on the wire

/// `captured_at`, the day and the segment, from the capture instant.
struct ScreenshotStamp: Equatable, Sendable {
    var rfc3339: String
    var day: String
    var segment: String

    init(date: Date, timeZone: TimeZone) {
        let whole = Int64(date.timeIntervalSince1970.rounded(.down))
        var offset = timeZone.secondsFromGMT(for: date)
        if offset % 60 != 0 { offset = 0 }
        var seconds = time_t(whole + Int64(offset))
        var parts = tm()
        gmtime_r(&seconds, &parts)
        let year = Int(parts.tm_year) + 1900
        let month = Int(parts.tm_mon) + 1
        let day = Int(parts.tm_mday)
        let hour = Int(parts.tm_hour)
        let minute = Int(parts.tm_min)
        let second = Int(parts.tm_sec)
        let dateText = "\(Self.pad(year, 4))-\(Self.pad(month, 2))-\(Self.pad(day, 2))"
        let timeText = "\(Self.pad(hour, 2)):\(Self.pad(minute, 2)):\(Self.pad(second, 2))"
        if offset == 0 {
            rfc3339 = "\(dateText)T\(timeText)Z"
        } else {
            let sign = offset < 0 ? "-" : "+"
            let magnitude = abs(offset)
            rfc3339 = "\(dateText)T\(timeText)\(sign)\(Self.pad(magnitude / 3600, 2)):\(Self.pad(magnitude % 3600 / 60, 2))"
        }
        self.day = "\(Self.pad(year, 4))\(Self.pad(month, 2))\(Self.pad(day, 2))"
        segment = "\(Self.pad(hour, 2))\(Self.pad(minute, 2))\(Self.pad(second, 2))_1"
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }
}

// MARK: - bytes

enum ScreenshotImageKind: Equatable, Sendable {
    case png, jpeg, webp, heic, tiff, gif, pdf, other

    var accepted: Bool {
        switch self {
        case .png, .jpeg, .webp: return true
        case .heic, .tiff, .gif, .pdf, .other: return false
        }
    }
}

enum ScreenshotBytes {
    static let maxBytes = 64 * 1024 * 1024
    static let maxPixels: Int64 = 100_000_000

    static func kind(header: Data) -> ScreenshotImageKind {
        let bytes = [UInt8](header.prefix(32))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if bytes.count >= 12,
           bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
           Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return .webp }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return .gif }
        if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) { return .pdf }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if heic(bytes) { return .heic }
        return .other
    }

    /// The name on the wire. A type the journal accepts keeps its own extension.
    /// Anything else is sent as PNG after the Mac converts it.
    static func uploadName(kind: ScreenshotImageKind, fileExtension: String) -> String {
        switch kind {
        case .png: return "screenshot_screen.png"
        case .jpeg:
            return fileExtension.lowercased() == "jpeg" ? "screenshot_screen.jpeg" : "screenshot_screen.jpg"
        case .webp: return "screenshot_screen.webp"
        case .heic, .tiff, .gif, .pdf, .other: return "screenshot_screen.png"
        }
    }

    /// PNG IHDR, JPEG SOF, or WebP VP8X. Nil when the header does not carry a size.
    static func pixelCount(data: Data) -> Int64? {
        switch kind(header: data) {
        case .png: return pngPixels(data)
        case .jpeg: return jpegPixels(data)
        case .webp: return webpPixels(data)
        default: return nil
        }
    }

    static func pngHeader(width: UInt32, height: UInt32) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52])
        data.append(contentsOf: width.bigEndianBytes)
        data.append(contentsOf: height.bigEndianBytes)
        return data
    }

    /// Size is known from the header for png, jpeg and webp, so those can be
    /// refused before a send. Any other type is judged after it becomes a PNG.
    static func refused(byteCount: Int, pixelCount: Int64?, kind: ScreenshotImageKind) -> Bool {
        guard kind.accepted else { return false }
        if byteCount > maxBytes { return true }
        if let pixelCount, pixelCount > maxPixels { return true }
        return false
    }

    private static func heic(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8) else { return false }
        let brands = ["heic", "heix", "hevc", "hevx", "mif1", "msf1", "heim", "heis"]
        let window = String(bytes: bytes.prefix(32), encoding: .ascii) ?? ""
        return brands.contains { window.contains($0) }
    }

    private static func pngPixels(_ data: Data) -> Int64? {
        guard data.count >= 24 else { return nil }
        let bytes = [UInt8](data)
        let width = UInt32(bytes[16]) << 24 | UInt32(bytes[17]) << 16 | UInt32(bytes[18]) << 8 | UInt32(bytes[19])
        let height = UInt32(bytes[20]) << 24 | UInt32(bytes[21]) << 16 | UInt32(bytes[22]) << 8 | UInt32(bytes[23])
        return Int64(width) * Int64(height)
    }

    private static func webpPixels(_ data: Data) -> Int64? {
        let bytes = [UInt8](data)
        guard bytes.count >= 30, Array(bytes[12..<16]) == Array("VP8X".utf8) else { return nil }
        let width = Int64(bytes[24]) | Int64(bytes[25]) << 8 | Int64(bytes[26]) << 16
        let height = Int64(bytes[27]) | Int64(bytes[28]) << 8 | Int64(bytes[29]) << 16
        return (width + 1) * (height + 1)
    }

    private static func jpegPixels(_ data: Data) -> Int64? {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var index = 2
        while index + 3 < bytes.count {
            if bytes[index] != 0xFF {
                index += 1
                continue
            }
            let marker = bytes[index + 1]
            if marker == 0x00 || marker == 0xFF || marker == 0x01 || (0xD0...0xD9).contains(marker) {
                index += 2
                continue
            }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            if length < 2 || index + 2 + length > bytes.count { return nil }
            let sized = marker != 0xC4 && marker != 0xC8 && marker != 0xCC && (0xC0...0xCF).contains(marker)
            if sized, index + 8 < bytes.count {
                let height = Int(bytes[index + 5]) << 8 | Int(bytes[index + 6])
                let width = Int(bytes[index + 7]) << 8 | Int(bytes[index + 8])
                return Int64(width) * Int64(height)
            }
            index += 2 + length
        }
        return nil
    }
}

private extension UInt32 {
    var bigEndianBytes: [UInt8] {
        [
            UInt8(truncatingIfNeeded: self >> 24),
            UInt8(truncatingIfNeeded: self >> 16),
            UInt8(truncatingIfNeeded: self >> 8),
            UInt8(truncatingIfNeeded: self),
        ]
    }
}

// MARK: - pause

struct ScreenshotPauseWindow: Codable, Equatable, Sendable {
    var start: Date
    var end: Date?
    var expiration: Date?
}

enum ScreenshotPause {
    /// A capture inside a window does not come in. The start counts and the end does not,
    /// so the moment of resume is included.
    static func excludes(_ date: Date, windows: [ScreenshotPauseWindow]) -> Bool {
        windows.contains { window in
            date >= window.start && (window.end.map { date < $0 } ?? true)
        }
    }
}

struct ScreenshotPauseFact: Equatable, Sendable {
    var paused: Bool
    var expiration: Date?

    static let running = ScreenshotPauseFact(paused: false, expiration: nil)
}

// MARK: - folder line

enum ScreenshotPaths {
    /// Home-relative parts joined with ` › `, the last three when the path is deeper.
    static func folderLine(path: String, home: String) -> String {
        let root = home.hasSuffix("/") ? String(home.dropLast()) : home
        let rest: String
        if path == root {
            rest = ""
        } else if path.hasPrefix(root + "/") {
            rest = String(path.dropFirst(root.count + 1))
        } else {
            rest = path
        }
        let parts = rest.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        let shown = parts.count > 3 ? Array(parts.suffix(3)) : parts
        let line = shown.joined(separator: " › ")
        return line.isEmpty ? (path as NSString).lastPathComponent : line
    }
}

// MARK: - what the journal answered

enum ScreenshotAnswer: Equatable, Sendable {
    case delivered
    case invalid
    case ahead
    case retry
}

func classifyScreenshot(statusCode: Int, body: Data) -> ScreenshotAnswer {
    if (200...299).contains(statusCode) {
        struct Answer: Decodable { let status: IngestProtocolV3.UploadStatus }
        guard (try? JSONDecoder().decode(Answer.self, from: body)) != nil else { return .retry }
        return .delivered
    }
    let parsed = parseIngestErrorBody(body)
    switch parsed.reasonCode {
    case "screenshot_invalid", "multipart_part_too_large": return .invalid
    case "screenshot_ahead": return .ahead
    default:
        if statusCode == 413 { return .invalid }
        return .retry
    }
}

// MARK: - a file the folder offered

struct ScreenshotCandidate: Equatable, Sendable {
    var path: String
    var marked: Bool
    var platformDate: Date?
    var fileDate: Date?
    var byteCount: Int
    var stable: Bool
    var header: Data
    var sha256: String?
    var pixelCount: Int64?
    var unreadable: Bool
    var fileExtension: String

    var when: Date? { platformDate ?? fileDate }
    var takenFrom: String? {
        if platformDate != nil { return "platform" }
        if fileDate != nil { return "file" }
        return nil
    }
    var identity: String? { sha256 }
}

struct ScreenshotFolder: Equatable, Sendable {
    var path: String
    var name: String
    var isDesktop: Bool
}

enum ScreenshotList: Equatable, Sendable {
    case files([ScreenshotCandidate])
    case denied
    case missing
    case failed
}

protocol ScreenshotReading: Sendable {
    func systemFolder() -> ScreenshotFolder
    func homePath() -> String
    func list(_ folder: ScreenshotFolder, now: Date) -> ScreenshotList
}

protocol ScreenshotTransport: Sendable {
    func capabilities(serverURL: String) async throws -> [String]
    func send(_ upload: ScreenshotUpload, serverURL: String) async -> ScreenshotAnswer
}

struct ScreenshotUpload: Equatable, Sendable {
    var sourcePath: String
    var fileName: String
    var day: String
    var segment: String
    var capturedAt: String
    var takenFrom: String
    var hash: String
}

// MARK: - the page and the tile

enum ScreenshotAccess: String, Codable, Equatable, Sendable {
    case ok, denied, moved
}

enum ScreenshotCount: Equatable, Sendable {
    case idle
    case checking
    case ready(Int)
    case failed
}

/// What the tile and the page say, derived from plain facts.
struct ScreenshotSnapshot: Equatable, Sendable {
    var state: DeckStateWord = .readyToSetUp
    var subline: String?
    var reason: String?
    var action: DeckSourceAction?
    var switchOn: Bool = false
    var pageNotice: String?
    var showChooser = false
    var span: ScreenshotSpan = .last30Days
    var confirmTitle = ScreenshotCopy.checking
    var confirmEnabled = false
    var showReturnNote = false
    var takesIn = ScreenshotCopy.takesIn
    var leavesAlone: String?
    var progress: String?
    var refusedLine: String?
    var unreadableLine: String?
    var folderPath: String?
    var lastChecked: Date?
    var waiting = 0
    var busy = false

    /// The page's one action for this state (desktop-shell § 2.7). Choosing another folder is
    /// not one of them: it sits with the `folder` fact.
    var pageActions: [DeckSourceAction] { action.map { [$0] } ?? [] }

    static let notSetUp = ScreenshotSnapshot(
        state: .readyToSetUp,
        subline: nil,
        reason: ScreenshotCopy.needsFolder("Desktop"),
        action: .allowScreenshotFolder,
        switchOn: false,
        leavesAlone: ScreenshotCopy.desktopStays("Desktop")
    )

    static func running(folderLine: String) -> ScreenshotSnapshot {
        var snapshot = ScreenshotSnapshot()
        snapshot.state = .on
        snapshot.subline = ScreenshotCopy.fromFolder(folderLine)
        snapshot.switchOn = true
        snapshot.leavesAlone = ScreenshotCopy.desktopStays("Desktop")
        return snapshot
    }
}

struct ScreenshotFacts: Equatable, Sendable {
    var consented = false
    var enabled = false
    var confirmed = false
    var access: ScreenshotAccess = .ok
    var accessHeld = true
    var ownerPaused = false
    var paired = true
    var waitingForJournal = false
    var folderName = "Desktop"
    var folderIsDesktop = true
    var folderFromOwner = false
    var folderLine = "Desktop"
    var folderPath: String?
    var span: ScreenshotSpan = .last30Days
    var count: ScreenshotCount = .idle
    var done = 0
    var total = 0
    var backlogOpen = false
    var refused = 0
    var unreadable = 0
    var waiting = 0
    var lastChecked: Date?
    var showReturnNote = false
    var movedName = "Desktop"
}

func presentScreenshots(_ facts: ScreenshotFacts) -> ScreenshotSnapshot {
    var snapshot = ScreenshotSnapshot()
    snapshot.span = facts.span
    snapshot.takesIn = ScreenshotCopy.takesIn
    // The folder is a fact in every state, so choosing another folder is reachable from it
    // before access is given too.
    snapshot.folderPath = facts.folderPath
    snapshot.lastChecked = facts.consented ? facts.lastChecked : nil
    snapshot.waiting = facts.waiting
    snapshot.showReturnNote = facts.showReturnNote && !facts.confirmed
    snapshot.refusedLine = facts.confirmed ? ScreenshotCopy.refusedLine(facts.refused) : nil
    snapshot.unreadableLine = facts.confirmed ? ScreenshotCopy.unreadableLine(facts.unreadable) : nil
    if facts.consented {
        // The Desktop's own sentence is for the folder the system uses. A folder the owner chose
        // gets the other sentence, including when that folder is the Desktop.
        snapshot.leavesAlone = facts.folderIsDesktop && !facts.folderFromOwner
            ? ScreenshotCopy.desktopStays(facts.folderName)
            : ScreenshotCopy.folderStays(facts.folderName)
    }
    switch facts.count {
    case .ready(let count):
        snapshot.confirmTitle = ScreenshotCopy.confirmTitle(spanFromToday: facts.span.fromToday, count: count)
        snapshot.confirmEnabled = true
    case .checking:
        snapshot.confirmTitle = ScreenshotCopy.checking
    case .idle, .failed:
        snapshot.confirmTitle = ScreenshotCopy.checking
    }

    if !facts.consented {
        // The folder's own sentence is the second half of the page's claim, so it is there before
        // the owner allows access, beside the reason that asks for it.
        snapshot.leavesAlone = facts.folderIsDesktop
            ? ScreenshotCopy.desktopStays(facts.folderName)
            : ScreenshotCopy.folderStays(facts.folderName)
        snapshot.state = .readyToSetUp
        snapshot.subline = nil
        snapshot.reason = ScreenshotCopy.needsFolder(facts.folderName)
        snapshot.action = .allowScreenshotFolder
        snapshot.pageNotice = snapshot.reason
        snapshot.switchOn = false
        return snapshot
    }
    if facts.access == .denied && !facts.accessHeld {
        // The owner said no at the system's prompt. Access was never held, so this is not a fault:
        // the source waits to be set up, and the reason says where access is turned on.
        snapshot.state = .readyToSetUp
        snapshot.subline = nil
        snapshot.reason = ScreenshotCopy.accessOff(facts.folderName)
        snapshot.pageNotice = snapshot.reason
        snapshot.action = .openScreenshotSettings
        snapshot.switchOn = false
        return snapshot
    }
    if facts.access == .denied {
        return attention(snapshot, line: ScreenshotCopy.accessOff(facts.folderName), action: .openScreenshotSettings)
    }
    if facts.access == .moved {
        return attention(snapshot, line: ScreenshotCopy.locationMoved(facts.movedName), action: .allowScreenshotFolder)
    }
    if !facts.enabled {
        let line = facts.paired ? DeckCopy.offPaired : DeckCopy.offUnpaired
        snapshot.state = .off
        snapshot.subline = line
        snapshot.reason = line
        snapshot.pageNotice = line
        snapshot.switchOn = false
        return snapshot
    }
    if !facts.confirmed {
        snapshot.switchOn = true
        snapshot.showChooser = true
        switch facts.count {
        case .checking:
            snapshot.state = .checking
            snapshot.busy = true
        case .failed:
            snapshot.state = .readyToSetUp
            snapshot.subline = ScreenshotCopy.chooseHowFar
            snapshot.reason = ScreenshotCopy.couldntCount
            snapshot.pageNotice = ScreenshotCopy.couldntCount
            snapshot.action = .retryScreenshotCount
        case .idle, .ready:
            snapshot.state = .readyToSetUp
            snapshot.subline = ScreenshotCopy.chooseHowFar
        }
        return snapshot
    }

    snapshot.switchOn = true
    let from = ScreenshotCopy.fromFolder(facts.folderLine)
    let bringingIn = facts.backlogOpen && facts.paired && !facts.waitingForJournal
    if facts.backlogOpen {
        snapshot.progress = ScreenshotCopy.pageProgress(done: facts.done, total: facts.total)
    }
    if facts.ownerPaused {
        snapshot.state = .paused
        snapshot.subline = ScreenshotCopy.pausedSkips
        snapshot.reason = ScreenshotCopy.pausedSkips
        snapshot.pageNotice = ScreenshotCopy.pausedSkips
        snapshot.action = .resumeIntake
    } else if bringingIn {
        snapshot.state = .on
        snapshot.subline = ScreenshotCopy.tileProgress(done: facts.done, total: facts.total)
        snapshot.pageNotice = snapshot.progress
        snapshot.busy = true
    } else {
        snapshot.state = .on
        snapshot.subline = from
        if facts.waitingForJournal {
            snapshot.pageNotice = ScreenshotCopy.waitingForJournal
            snapshot.reason = ScreenshotCopy.waitingForJournal
        }
    }
    return snapshot
}

private func attention(_ snapshot: ScreenshotSnapshot, line: String, action: DeckSourceAction) -> ScreenshotSnapshot {
    var snapshot = snapshot
    snapshot.state = .needsAttention
    snapshot.subline = line
    snapshot.reason = line
    snapshot.pageNotice = line
    snapshot.action = action
    snapshot.switchOn = true
    return snapshot
}
