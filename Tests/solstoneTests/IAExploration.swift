// EXPLORATION — Settings IA design mocks for founder review (VPX).
// Throwaway design scaffolding, test-target only. Renders 5 static mock PNGs.
// Not wired to AppState or any shipped view. No shipped behavior or copy is affected.
// remove when the Settings IA is chosen and implemented.

import AppKit
import SwiftUI
import Testing

private func runGit(_ args: String...) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = Array(args)
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func makeSnapshotOutputDir() throws -> URL {
    let repoRoot = try runGit("rev-parse", "--show-toplevel")
    let gitHash = try runGit("rev-parse", "--short", "HEAD")

    let dirtyCheck = Process()
    dirtyCheck.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    dirtyCheck.arguments = ["diff", "--quiet", "HEAD"]
    dirtyCheck.currentDirectoryURL = URL(fileURLWithPath: repoRoot)
    try dirtyCheck.run()
    dirtyCheck.waitUntilExit()
    let isDirty = dirtyCheck.terminationStatus != 0

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HHmmss"
    let dirName = "\(formatter.string(from: Date()))_\(gitHash)\(isDirty ? "-dirty" : "")"

    let url = URL(fileURLWithPath: repoRoot).appendingPathComponent("snapshots/\(dirName)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Snapshots — IA Exploration")
@MainActor
struct IAExplorationSnapshots {
    private static nonisolated(unsafe) var _outputDir: URL?

    private var outputDir: URL {
        get throws {
            if let dir = Self._outputDir { return dir }
            let dir = try makeSnapshotOutputDir()
            Self._outputDir = dir
            return dir
        }
    }

    private let sidebarSize = CGSize(width: 220, height: 540)
    private let detailSize = CGSize(width: 560, height: 660)
    private let emptinessThreshold = 0.95  // blank-pane regressions (5fd16e5) rendered ~99% near-white; healthy snapshots stay below ~85%

    init() {
        _ = NSApplication.shared
    }

    @Test func iaSidebarA() throws {
        try render(
            IASidebarMock(
                selectedID: "status",
                leadingStatus: true,
                middleHeader: "inputs",
                bottomHeader: "app",
                middleItems: [
                    IASidebarItem(id: "microphones", title: "microphones", systemImage: "mic"),
                    IASidebarItem(id: "privacy", title: "privacy", systemImage: "eye.slash"),
                ],
                bottomItems: [
                    IASidebarItem(id: "general", title: "general", systemImage: "gearshape"),
                    IASidebarItem(id: "updates", title: "updates", systemImage: "arrow.down.circle"),
                    IASidebarItem(id: "help", title: "help", systemImage: "questionmark.circle"),
                ]
            ),
            size: sidebarSize,
            to: "ia-sidebar-A.png"
        )
    }

    @Test func iaSidebarB() throws {
        try render(
            IASidebarMock(
                selectedID: "journal",
                leadingStatus: false,
                middleHeader: "inputs",
                bottomHeader: "app",
                middleItems: [
                    IASidebarItem(id: "microphones", title: "microphones", systemImage: "mic"),
                    IASidebarItem(id: "privacy", title: "privacy", systemImage: "eye.slash"),
                ],
                bottomItems: [
                    IASidebarItem(id: "general", title: "general", systemImage: "gearshape"),
                    IASidebarItem(id: "updates", title: "updates", systemImage: "arrow.down.circle"),
                    IASidebarItem(id: "help", title: "help", systemImage: "questionmark.circle"),
                ]
            ),
            size: sidebarSize,
            to: "ia-sidebar-B.png"
        )
    }

    @Test func iaSidebarC() throws {
        try render(
            IASidebarMock(
                selectedID: "status",
                leadingStatus: true,
                middleHeader: "preferences",
                bottomHeader: "system",
                middleItems: [
                    IASidebarItem(id: "general", title: "general", systemImage: "gearshape"),
                    IASidebarItem(id: "microphones", title: "microphones", systemImage: "mic"),
                    IASidebarItem(id: "privacy", title: "privacy", systemImage: "eye.slash"),
                ],
                bottomItems: [
                    IASidebarItem(id: "updates", title: "updates", systemImage: "arrow.down.circle"),
                    IASidebarItem(id: "help", title: "help", systemImage: "questionmark.circle"),
                ]
            ),
            size: sidebarSize,
            to: "ia-sidebar-C.png"
        )
    }

    @Test func iaJournalConsolidated() throws {
        try render(
            IAJournalConsolidatedMock(),
            size: detailSize,
            to: "ia-journal-consolidated.png"
        )
    }

    @Test func iaStatusHome() throws {
        try render(
            IAStatusHomeMock(),
            size: detailSize,
            to: "ia-status-home.png"
        )
    }

    private func render<V: View>(_ view: V, size: CGSize, to filename: String) throws {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw RenderError.noBitmap
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)

        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            throw RenderError.noPNG
        }

        let url = try outputDir.appendingPathComponent(filename)
        try pngData.write(to: url)

        guard let bitmapData = bitmapRep.bitmapData else { return }
        let bytesPerPixel = bitmapRep.bitsPerPixel / 8
        let bytesPerRow = bitmapRep.bytesPerRow
        let width = bitmapRep.pixelsWide
        let height = bitmapRep.pixelsHigh
        var backgroundCount = 0
        for y in 0..<height {
            for x in 0..<width {
                let pixel = bitmapData.advanced(by: y * bytesPerRow + x * bytesPerPixel)
                if pixel[0] >= 250, pixel[1] >= 250, pixel[2] >= 250 {
                    backgroundCount += 1
                }
            }
        }
        let whiteRatio = Double(backgroundCount) / Double(width * height)
        if whiteRatio > emptinessThreshold {
            throw RenderError.emptyContent(filename: filename, whiteRatio: whiteRatio, threshold: emptinessThreshold)
        }
    }

    private enum RenderError: Error, CustomStringConvertible {
        case noBitmap
        case noPNG
        case emptyContent(filename: String, whiteRatio: Double, threshold: Double)

        var description: String {
            switch self {
            case .noBitmap: return "failed to create bitmap rep"
            case .noPNG: return "failed to encode PNG"
            case let .emptyContent(filename, whiteRatio, threshold):
                return "\(filename): \(String(format: "%.3f", whiteRatio)) near-white exceeds \(String(format: "%.2f", threshold)) threshold"
            }
        }
    }
}

private enum IABadge {
    case none, done, attention
}

private struct IASidebarItem: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let badge: IABadge

    init(id: String, title: String, systemImage: String, badge: IABadge = .none) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.badge = badge
    }
}

private struct IASidebarMock: View {
    let selectedID: String
    let leadingStatus: Bool
    let middleHeader: String
    let bottomHeader: String
    let middleItems: [IASidebarItem]
    let bottomItems: [IASidebarItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if leadingStatus {
                iaSidebarRow("status", systemImage: "info.circle", selected: selectedID == "status")
            }

            iaSidebarSectionHeader("setup")
            iaSidebarRow("permissions", systemImage: "lock.shield", selected: selectedID == "permissions", badge: .attention)
            iaSidebarRow("journal", systemImage: "book.closed", selected: selectedID == "journal", badge: .done)

            iaSidebarSectionHeader(middleHeader)
            ForEach(middleItems) { item in
                iaSidebarRow(item.title, systemImage: item.systemImage, selected: selectedID == item.id, badge: item.badge)
            }

            iaSidebarSectionHeader(bottomHeader)
            ForEach(bottomItems) { item in
                iaSidebarRow(item.title, systemImage: item.systemImage, selected: selectedID == item.id, badge: item.badge)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(width: 220, height: 540, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private func iaSidebarSectionHeader(_ title: String) -> some View {
    Text(title)
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 2)
}

private func iaSidebarRow(_ title: String, systemImage: String, selected: Bool, badge: IABadge = .none) -> some View {
    HStack(spacing: 6) {
        Image(systemName: systemImage)
            .foregroundStyle(selected ? Color.white : Color.secondary)
        Text(title)
            .foregroundStyle(selected ? Color.white : Color.primary)
        Spacer()
        switch badge {
        case .none:
            EmptyView()
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(selected ? Color.white : Color.secondary)
        case .attention:
            Circle()
                .fill(.orange)
                .frame(width: 7, height: 7)
        }
    }
    .font(.body)
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
        if selected {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor)
        }
    }
}

private struct IAJournalConsolidatedMock: View {
    @State private var mode = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                iaGroupBox("live status") {
                    LabeledContent("state") {
                        Text("observing")
                    }
                    LabeledContent("next save in") {
                        Text("3:21")
                    }
                }

                iaGroupBox("journal mode") {
                    Text("set up your journal")
                        .font(.headline)
                    Picker("journal mode", selection: $mode) {
                        Text("this Mac").tag(0)
                        Text("another machine").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    iaTradeoffLine(
                        label: "this Mac",
                        text: "solstone runs the full system on this Mac and hosts your journal here. recommended if you're just getting started."
                    )
                    iaTradeoffLine(
                        label: "another machine",
                        text: "this Mac becomes an observer feeding a journal that lives on another machine — your other Mac, your home server, or a journal you've been invited to."
                    )
                }

                DisclosureGroup("sync & storage", isExpanded: .constant(true)) {
                    VStack(alignment: .leading, spacing: 16) {
                        iaGroupBox("sync") {
                            LabeledContent("journal") {
                                Text("running")
                            }
                            HStack {
                                Image(systemName: "checkmark.circle")
                                    .foregroundStyle(.green)
                                Text("synced")
                            }
                            Toggle("pause sync", isOn: .constant(false))
                            HStack {
                                Button("resync all") {}
                                Button("configure journal →") {}
                                    .font(.caption)
                                    .buttonStyle(.link)
                            }
                        }

                        iaGroupBox("storage") {
                            LabeledContent("currently using") {
                                Text("42 MB")
                            }
                            LabeledContent("keep on this Mac for") {
                                Picker("", selection: .constant(7)) {
                                    Text("don't keep").tag(0)
                                    Text("7 days").tag(7)
                                    Text("14 days").tag(14)
                                    Text("30 days").tag(30)
                                    Text("60 days").tag(60)
                                    Text("forever").tag(-1)
                                }
                                .labelsHidden()
                                .frame(width: 120)
                            }
                            LabeledContent("storage folder") {
                                Button("open in Finder") {}
                            }
                            iaCaption("synced segments older than the retention period are removed from your Mac. unsynced segments are never deleted.")
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: 560, height: 660)
    }
}

private struct IAStatusHomeMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            iaGroupBox("observing") {
                Text("observing")
                    .font(.title2)
                Text("next save in 3:21")
                    .foregroundStyle(.secondary)
            }

            iaGroupBox("journal") {
                Text("journal — running · synced")
                Button("manage journal →") {}
                    .font(.caption)
                    .buttonStyle(.link)
            }

            iaGroupBox("storage") {
                Text("42 MB on this Mac · keeping 7 days")
                Button("storage settings →") {}
                    .font(.caption)
                    .buttonStyle(.link)
            }

            iaCaption("permissions granted · 2 microphones · syncing to this Mac")

            Spacer()
        }
        .padding(20)
        .frame(width: 560, height: 660, alignment: .topLeading)
    }
}

private func iaGroupBox<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    GroupBox(title) {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(.vertical, 4)
    }
}

private func iaCaption(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
}

private func iaTradeoffLine(label: String, text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text("\(label):")
            .fontWeight(.semibold)
        Text(text)
            .foregroundStyle(.secondary)
    }
    .font(.caption)
}
