// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import os
@testable import solstone

/// An AX-like tree for Firefox windows, served to `LiveFirefoxWindowReader` through its attribute,
/// pairing and window-server seams. Every handle is an AX element for a negative pid, which no
/// process can have, and every read goes through the seams, so no test reaches a real process. Before a pid's engine is triggered its windows hold nothing,
/// as measured; after the trigger they hold the whole tree.
final class FakeFirefoxTree: @unchecked Sendable {
    struct Node {
        var role: String?
        var roleError: AXError = .success
        var subrole: String?
        var children: [Int] = []
        var childrenError: AXError = .success
        var url: String?
        var urlError: AXError = .success
        var frame: CGRect?
        var frameError: AXError = .success
        var title: String?
        var titleError: AXError = .success
        var value: String?
        /// For a window: the pid it belongs to, whose engine gates its children.
        var windowPID: pid_t?
    }

    private let lock = NSRecursiveLock()
    private var nodes: [Int: Node] = [:]
    private var elementByID: [Int: AXUIElement] = [:]
    private var idByElement: [AXUIElement: Int] = [:]
    private var nextID = 1
    /// AXWindows per pid, as node ids.
    private var axWindows: [pid_t: [Int]] = [:]
    private var windowIDs: [Int: CGWindowID] = [:]
    private var engineOn: Set<pid_t> = []

    var engineComesUp = true
    var axWindowsFails: Set<pid_t> = []
    var pairingFails: Set<Int> = []
    var cgTitles: [CGWindowID: String] = [:]
    /// Called on every attribute read, for a test clock.
    var onRead: (@Sendable () -> Void)?
    private(set) var triggerCount: [pid_t: Int] = [:]
    private(set) var attributeLog: [(id: Int?, attribute: String)] = []

    init() {}

    func locked<T>(_ body: (FakeFirefoxTree) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(self)
    }

    @discardableResult
    func add(_ node: Node) -> Int {
        locked { tree in
            let id = tree.nextID
            tree.nextID += 1
            let element = AXUIElementCreateApplication(-pid_t(100_000 + id))
            tree.nodes[id] = node
            tree.elementByID[id] = element
            tree.idByElement[element] = id
            return id
        }
    }

    func update(_ id: Int, _ change: (inout Node) -> Void) {
        locked { tree in
            if var node = tree.nodes[id] {
                change(&node)
                tree.nodes[id] = node
            }
        }
    }

    func node(_ id: Int) -> Node? { locked { $0.nodes[id] } }
    func element(_ id: Int) -> AXUIElement { locked { $0.elementByID[id]! } }

    func setEngine(_ on: Bool, pid: pid_t) {
        locked { tree in
            if on { tree.engineOn.insert(pid) } else { tree.engineOn.remove(pid) }
        }
    }

    func isEngineOn(_ pid: pid_t) -> Bool { locked { $0.engineOn.contains(pid) } }

    func listWindows(_ ids: [Int], pid: pid_t) {
        locked { $0.axWindows[pid] = ids }
    }

    func appendWindow(_ id: Int, pid: pid_t) {
        locked { $0.axWindows[pid, default: []].append(id) }
    }

    func setWindowID(_ wid: CGWindowID, for id: Int) {
        locked { $0.windowIDs[id] = wid }
    }

    func clearLog() { locked { $0.attributeLog.removeAll() } }

    // MARK: building windows

    struct WindowIDs {
        var window: Int
        var container: Int
        var tabPanel: Int
        var pageScroll: Int
        var page: Int
        var sidebar: Int?
        var devtools: Int?
        var tabStrip: Int
    }

    static let windowFrame = CGRect(x: 0, y: 25, width: 1440, height: 965)
    static let contentFrame = CGRect(x: 40, y: 125, width: 1400, height: 865)

    /// A Firefox window as measured: a container holding the tab strip and navigation toolbars, an
    /// optional sidebar outside the tab panel, and one tab panel holding the shown page and, docked,
    /// devtools.
    @discardableResult
    func addBrowserWindow(
        pid: pid_t,
        wid: CGWindowID,
        title: String,
        pageURL: String?,
        tabs: Int = 5,
        sidebarURL: String? = nil,
        devtoolsURL: String? = nil,
        findBar: Bool = false,
        splitView: Bool = false,
        listed: Bool = true
    ) -> WindowIDs {
        var tabButtons: [Int] = []
        for i in 0..<tabs {
            let a = add(Node(role: "AXStaticText", value: "Tab \(i)"))
            let b = add(Node(role: "AXButton"))
            let c = add(Node(role: "AXImage"))
            tabButtons.append(add(Node(role: "AXRadioButton", subrole: "AXTabButton", children: [a, b, c], title: "Tab \(i)")))
        }
        let tabGroup = add(Node(role: "AXTabGroup", children: tabButtons))
        let tabStrip = add(Node(role: "AXToolbar", children: [tabGroup]))
        let combo = add(Node(role: "AXComboBox", value: "typed text that is never read"))
        let nav = add(Node(role: "AXToolbar", children: [add(Node(role: "AXButton")), combo]))

        var pageFrame = Self.contentFrame
        var devtools: Int?
        var panelChildren: [Int] = []
        if let devtoolsURL {
            pageFrame = CGRect(x: 40, y: 125, width: 1400, height: 600)
            let area = add(Node(role: "AXWebArea", url: devtoolsURL, frame: CGRect(x: 40, y: 730, width: 1400, height: 260)))
            devtools = area
            panelChildren.append(add(Node(role: "AXSplitter", subrole: "AXContentSeparator")))
            panelChildren.append(add(Node(role: "AXScrollArea", children: [area])))
        }
        if findBar {
            let field = add(Node(role: "AXTextField", value: "find text that is never read"))
            panelChildren.append(add(Node(role: "AXToolbar", children: [add(Node(role: "AXButton")), field, add(Node(role: "AXCheckBox"))])))
        }
        // The group holding the tab panel: the content area right of any sidebar. One page's panel
        // fills it; a split view's panel is one pane, inset about 3 points on every side.
        let deckFrame = sidebarURL == nil ? Self.contentFrame : CGRect(x: 384, y: 125, width: 1056, height: 865)
        var panelFrame = deckFrame
        if splitView {
            // As measured on 162 with the other pane focused: one pane's page only, then two
            // labelled groups and the split view button. The other pane's page isn't in the tree at
            // all. With the exposed pane focused, the groups and button go (`m5`).
            panelFrame = CGRect(x: deckFrame.minX + 3, y: deckFrame.minY + 3, width: deckFrame.width / 2 - 6, height: deckFrame.height - 6)
            pageFrame = panelFrame.insetBy(dx: 1, dy: 1)
            for _ in 0..<2 {
                panelChildren.append(add(Node(role: "AXGroup", subrole: "AXUnknown", children: [add(Node(role: "AXStaticText"))])))
            }
            panelChildren.append(add(Node(role: "AXButton", children: [add(Node(role: "AXGroup", subrole: "AXUnknown"))])))
        }
        let page = add(Node(role: "AXWebArea", url: pageURL, frame: pageFrame))
        let pageScroll = add(Node(role: "AXScrollArea", children: [page]))
        panelChildren.insert(pageScroll, at: 0)
        let tabPanel = add(Node(role: "AXGroup", subrole: "AXTabPanel", children: panelChildren, frame: panelFrame))
        let deck = add(Node(role: "AXGroup", subrole: "AXUnknown", children: [tabPanel], frame: deckFrame))

        var containerChildren = [tabStrip, nav]
        var sidebar: Int?
        if let sidebarURL {
            let area = add(Node(role: "AXWebArea", url: sidebarURL, frame: CGRect(x: 40, y: 188, width: 339, height: 802)))
            sidebar = area
            let scroll = add(Node(role: "AXScrollArea", children: [area]))
            containerChildren.append(add(Node(role: "AXGroup", subrole: "AXUnknown", children: [scroll])))
        }
        containerChildren.append(deck)
        let container = add(Node(role: "AXGroup", subrole: "AXUnknown", children: containerChildren))
        let window = add(Node(role: "AXWindow", subrole: "AXStandardWindow", children: [container], frame: Self.windowFrame, title: title, windowPID: pid))
        setWindowID(wid, for: window)
        if listed { appendWindow(window, pid: pid) }
        locked { $0.cgTitles[wid] = title }
        return WindowIDs(window: window, container: container, tabPanel: tabPanel, pageScroll: pageScroll, page: page, sidebar: sidebar, devtools: devtools, tabStrip: tabStrip)
    }

    /// A window with no tab panel, such as the Library.
    @discardableResult
    func addLibraryWindow(pid: pid_t, wid: CGWindowID) -> Int {
        let list = add(Node(role: "AXOutline"))
        let group = add(Node(role: "AXGroup", subrole: "AXUnknown", children: [list]))
        let window = add(Node(role: "AXWindow", children: [group], frame: CGRect(x: 100, y: 100, width: 800, height: 500), title: "Library", windowPID: pid))
        setWindowID(wid, for: window)
        appendWindow(window, pid: pid)
        locked { $0.cgTitles[wid] = "Library" }
        return window
    }

    /// Picture in Picture as measured: an `about:blank` web area, controls, and no origin text.
    @discardableResult
    func addPiPWindow(pid: pid_t, wid: CGWindowID, originText: String? = nil) -> Int {
        let area = add(Node(role: "AXWebArea", url: "about:blank", frame: CGRect(x: 1280, y: 645, width: 640, height: 360)))
        var controls = [add(Node(role: "AXButton")), add(Node(role: "AXSlider"))]
        if let originText { controls.append(add(Node(role: "AXStaticText", value: originText))) }
        let group = add(Node(role: "AXGroup", subrole: "AXApplicationGroup", children: controls))
        let scroll = add(Node(role: "AXScrollArea", children: [area]))
        let window = add(Node(role: "AXWindow", children: [scroll, group], frame: CGRect(x: 1280, y: 645, width: 640, height: 360), title: "Picture-in-Picture", windowPID: pid))
        setWindowID(wid, for: window)
        appendWindow(window, pid: pid)
        locked { $0.cgTitles[wid] = "" }
        return window
    }

    // MARK: the seams

    func makeReader(recorder: AXReadRecorder? = nil) -> LiveFirefoxWindowReader {
        let reader = LiveFirefoxWindowReader(recorder: recorder)
        reader.copyAttribute = { [unowned self] element, attribute in
            self.copy(element, attribute as String)
        }
        reader.pairWindow = { [unowned self] element in
            self.locked { tree in
                guard let id = tree.idByElement[element], !tree.pairingFails.contains(id) else { return nil }
                return tree.windowIDs[id]
            }
        }
        reader.windowServerTitle = { [unowned self] wid in
            self.locked { $0.cgTitles[wid] }
        }
        return reader
    }

    private func copy(_ element: AXUIElement, _ attribute: String) -> (AXError, CFTypeRef?) {
        onRead?()
        return locked { tree in
            // Application elements.
            for pid in Set(tree.axWindows.keys).union(tree.axWindowsFails) where CFEqual(element, AXUIElementCreateApplication(pid)) {
                tree.attributeLog.append((nil, attribute))
                switch attribute {
                case "AXRole":
                    tree.triggerCount[pid, default: 0] += 1
                    if tree.engineComesUp { tree.engineOn.insert(pid) }
                    return (.success, kAXApplicationRole as CFTypeRef)
                case "AXWindows":
                    if tree.axWindowsFails.contains(pid) { return (.cannotComplete, nil) }
                    let windows = (tree.axWindows[pid] ?? []).compactMap { tree.elementByID[$0] }
                    return (.success, windows as CFArray)
                default:
                    return (.attributeUnsupported, nil)
                }
            }
            guard let id = tree.idByElement[element], let node = tree.nodes[id] else { return (.invalidUIElement, nil) }
            tree.attributeLog.append((id, attribute))
            switch attribute {
            case "AXRole":
                guard node.roleError == .success else { return (node.roleError, nil) }
                return node.role.map { (.success, $0 as CFTypeRef) } ?? (.noValue, nil)
            case "AXSubrole":
                return node.subrole.map { (.success, $0 as CFTypeRef) } ?? (.noValue, nil)
            case "AXChildren":
                guard node.childrenError == .success else { return (node.childrenError, nil) }
                var children = node.children
                if let pid = node.windowPID, !tree.engineOn.contains(pid) { children = [] }
                return (.success, children.compactMap { tree.elementByID[$0] } as CFArray)
            case "AXURL":
                guard node.urlError == .success else { return (node.urlError, nil) }
                guard let url = node.url else { return (.noValue, nil) }
                if !url.isEmpty, let parsed = URL(string: url) { return (.success, parsed as CFURL) }
                return (.success, url as CFString)
            case "AXPosition":
                guard node.frameError == .success, var origin = node.frame?.origin else { return (node.frameError == .success ? .noValue : node.frameError, nil) }
                return (.success, AXValueCreate(.cgPoint, &origin))
            case "AXSize":
                guard node.frameError == .success, var size = node.frame?.size else { return (node.frameError == .success ? .noValue : node.frameError, nil) }
                return (.success, AXValueCreate(.cgSize, &size))
            case "AXTitle":
                guard node.titleError == .success else { return (node.titleError, nil) }
                return node.title.map { (.success, $0 as CFTypeRef) } ?? (.noValue, nil)
            case "AXValue":
                return node.value.map { (.success, $0 as CFTypeRef) } ?? (.noValue, nil)
            default:
                return (.attributeUnsupported, nil)
            }
        }
    }
}

/// The website sampler over a fake Firefox, on an injected clock. Each `poll()` runs one CG poll and
/// waits for its Firefox round.
final class FirefoxSamplerHarness: @unchecked Sendable {
    let tree: FakeFirefoxTree
    let recorder = AXReadRecorder()
    let clock = OSAllocatedUnfairLock(initialState: 100.0)
    private let screen = OSAllocatedUnfairLock(initialState: [SiteVisibleWindow]())
    private let eligiblePIDs: OSAllocatedUnfairLock<Set<pid_t>>
    private let firefoxPIDs: OSAllocatedUnfairLock<Set<pid_t>>
    private var rounds: AsyncStream<[CGWindowID: ChromiumPollRead]>.Iterator
    private let roundsContinuation: AsyncStream<[CGWindowID: ChromiumPollRead]>.Continuation
    let cautions = OSAllocatedUnfairLock(initialState: [(PrivateBrowser, Bool)]())
    let polls = OSAllocatedUnfairLock(initialState: [SitePollSnapshot]())
    private(set) var sampler: SiteSampler!

    init(
        tree: FakeFirefoxTree = FakeFirefoxTree(),
        firefoxPIDs: Set<pid_t> = [-700],
        eligible: Set<pid_t> = [-700],
        axWorking: Bool = true,
        chromiumReader: ChromiumWindowReading? = nil,
        chromePIDs: Set<pid_t> = [],
        reader: FirefoxWindowReading? = nil
    ) {
        self.tree = tree
        self.eligiblePIDs = OSAllocatedUnfairLock(initialState: eligible)
        self.firefoxPIDs = OSAllocatedUnfairLock(initialState: firefoxPIDs)
        let (stream, continuation) = AsyncStream<[CGWindowID: ChromiumPollRead]>.makeStream()
        rounds = stream.makeAsyncIterator()
        roundsContinuation = continuation
        var hooks = SiteSamplerHooks()
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.chromePIDs = { chromePIDs }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        let firefox = self.firefoxPIDs
        let eligibleSet = self.eligiblePIDs
        hooks.firefoxPIDs = { firefox.withLock { $0 } }
        hooks.firefoxEligible = { pid in eligibleSet.withLock { $0.contains(pid) } }
        let screen = self.screen
        hooks.copyOnScreen = { screen.withLock { $0 } }
        let clock = self.clock
        hooks.nowTicks = { FirefoxTestClock.ticks(seconds: clock.withLock { $0 }) }
        hooks.firefoxReader = reader ?? tree.makeReader(recorder: recorder)
        if let chromiumReader { hooks.chromiumReader = chromiumReader }
        let roundSink = roundsContinuation
        let cautions = self.cautions
        let polls = self.polls
        sampler = SiteSampler(
            probe: AccessibilityProbe(readWorks: { axWorking }, prompt: {}),
            isSnapshot: true,
            hooks: hooks,
            onPoll: { poll in polls.withLock { $0.append(poll) } },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { browser, results, _, _ in
                guard browser == .firefox else { return }
                roundSink.yield(results.mapValues(\.read))
            },
            onChromiumCautionUpdate: { browser, caution in
                cautions.withLock { $0.append((browser, caution)) }
            }
        )
    }

    func start(sites: [String], axWorking: Bool = true) async {
        await sampler.applySites(sites, generation: 1)
        await sampler.setAXWorkingForTesting(axWorking)
    }

    func show(_ windows: [SiteVisibleWindow]) {
        screen.withLock { $0 = windows }
    }

    func setEligible(_ pids: Set<pid_t>) { eligiblePIDs.withLock { $0 = pids } }

    var now: TimeInterval { clock.withLock { $0 } }

    func advance(_ seconds: TimeInterval) { clock.withLock { $0 += seconds } }

    /// One CG poll, then its Firefox round's reads. Nil when no round was due.
    @discardableResult
    func poll(advancing step: TimeInterval = 0.25, expectRound: Bool = true) async -> [CGWindowID: ChromiumPollRead]? {
        await sampler.performPollForTesting()
        var result: [CGWindowID: ChromiumPollRead]?
        if expectRound {
            result = await rounds.next()
        }
        advance(step)
        return result
    }

    var firefoxCautionRaised: Bool {
        cautions.withLock { $0.last(where: { $0.0 == .firefox })?.1 ?? false }
    }
}

enum FirefoxTestClock {
    static func ticks(seconds: TimeInterval) -> UInt64 {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return UInt64((seconds * 1_000_000_000.0 * Double(info.denom)) / Double(info.numer))
    }
}
