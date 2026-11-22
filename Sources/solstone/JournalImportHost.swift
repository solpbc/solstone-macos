// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import os
import UniformTypeIdentifiers
import WebKit

private let importHostLog = Logger(subsystem: "app.solstone.observer", category: "import")

/// The journal page's import handoff contract, version 2, read from the copy packaged with the
/// app. The page checks the version and the request type the host advertises; every name the
/// script and the reply use comes from here.
struct JournalImportContract: Equatable, Sendable {
    let version: Int
    let capability: String
    let pick: String
    let reply: String
    let status: String
    let event: String
    let drop: String
    let unsupported: String
    let contextMaxBytes: Int
    /// The packaged bytes, handed to the page script as they are.
    let json: String

    static let supportedVersion = 2

    init?(data: Data?) {
        guard let data, let json = String(data: data, encoding: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = object["version"] as? Int, version == Self.supportedVersion,
              let capability = object["capability"] as? String, !capability.isEmpty,
              let pick = object["pick"] as? String, !pick.isEmpty,
              let reply = object["reply"] as? String, !reply.isEmpty,
              let status = object["status"] as? String, !status.isEmpty,
              let event = object["event"] as? String, !event.isEmpty,
              let drop = object["drop"] as? String, !drop.isEmpty,
              let unsupported = object["unsupported"] as? String, !unsupported.isEmpty,
              let contextMaxBytes = object["contextMaxBytes"] as? Int, contextMaxBytes > 0
        else { return nil }
        self.version = version
        self.capability = capability
        self.pick = pick
        self.reply = reply
        self.status = status
        self.event = event
        self.drop = drop
        self.unsupported = unsupported
        self.contextMaxBytes = contextMaxBytes
        self.json = json.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func packaged(appBundle: Bundle = .main) -> JournalImportContract? {
        JournalImportContract(data: JournalWebHostContract.packagedBytes(appBundle: appBundle, resource: "import-host-contract"))
    }
}

/// Where the handoff puts what it holds: the app's own import store and upload queue, the one
/// the import page's own picker and drops use.
@MainActor
protocol JournalImportIntake: AnyObject {
    func addHandedOver(_ urls: [URL], handoff: ImportHandoff) async -> ImportAddResult
    func handoffStatus(_ id: String) async -> ImportHandoffStatus
}

extension ImportSource: JournalImportIntake {}

/// What the page asked the picker for.
struct JournalImportPickerRequest: Equatable, Sendable {
    var types: [UTType]
    var multiple: Bool
}

/// The journal window's import host. It advertises the capability to the top journal document
/// only, on the paired journal's live origin, takes the page's requests over a reply handler,
/// lets the owner pick or drop files, and puts them in the app's import queue before answering
/// `queued`. The page never sees a path, file bytes or the pairing credential: it gets queue item
/// ids, display names and status.
@MainActor
final class JournalImportHost: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "journalImport"
    static let dropLifetime: TimeInterval = 60
    private static let maxIDLength = 128
    private static let maxAcceptEntries = 64

    let contract: JournalImportContract
    let authHost: JournalAuthHost?
    private let intake: @MainActor () -> (any JournalImportIntake)?
    private let liveBaseURL: @MainActor () -> URL?
    private let presentPicker: @MainActor (JournalImportPickerRequest, NSWindow?) async -> [URL]?
    private let clock: () -> Date
    weak var webView: WKWebView?
    private var picking = false
    private var drops: [String: (urls: [URL], expires: Date)] = [:]
    /// The current top document said its page takes the handoff, so drops are this host's.
    private(set) var pageAcceptsHandoff = false

    init(
        contract: JournalImportContract,
        authHost: JournalAuthHost? = JournalAuthContract.packaged().map { JournalAuthHost(contract: $0) },
        intake: @escaping @MainActor () -> (any JournalImportIntake)?,
        liveBaseURL: @escaping @MainActor () -> URL?,
        presentPicker: @escaping @MainActor (JournalImportPickerRequest, NSWindow?) async -> [URL]? = JournalImportPicker.present,
        clock: @escaping () -> Date = Date.init
    ) {
        self.contract = contract
        self.authHost = authHost
        self.intake = intake
        self.liveBaseURL = liveBaseURL
        self.presentPicker = presentPicker
        self.clock = clock
    }

    // MARK: - what the page gets

    /// The page origin as a document reports it in `location.origin`.
    static func documentOrigin(of url: URL) -> String? {
        guard let origin = JournalWindowOrigin(url: url) else { return nil }
        let defaultPort = origin.scheme == "https" ? 443 : 80
        let host = origin.host.contains(":") ? "[\(origin.host)]" : origin.host
        return origin.port == defaultPort ? "\(origin.scheme)://\(host)" : "\(origin.scheme)://\(host):\(origin.port)"
    }

    /// The script that advertises the capability. It runs in the top document only, at document
    /// start, and does nothing unless that document is on `baseURL`'s origin.
    func userScript(for baseURL: URL) -> WKUserScript? {
        guard let origin = Self.documentOrigin(of: baseURL),
              let originLiteral = try? String(data: JSONSerialization.data(withJSONObject: [origin], options: [.withoutEscapingSlashes]), encoding: .utf8),
              let handlerLiteral = try? String(data: JSONSerialization.data(withJSONObject: [Self.handlerName]), encoding: .utf8)
        else { return nil }
        let authLiteral = authHost?.contract.json ?? "null"
        // Array literals keep each value a valid JS expression; the script takes element 0.
        let source = "(\(Self.scriptBody))(\(contract.json), \(originLiteral)[0], \(handlerLiteral)[0], \(authLiteral));"
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
    }

    /// Puts the capability script for the origin the window is about to load in place of any
    /// earlier one, so a document on another origin never gets it.
    func install(on controller: WKUserContentController, for baseURL: URL) {
        controller.removeAllUserScripts()
        if let script = userScript(for: baseURL) { controller.addUserScript(script) }
    }

    /// A new top document: whatever the last one said about drops or auth sessions no longer holds.
    func mainFrameCommitted() {
        pageAcceptsHandoff = false
        authHost?.tearDown()
    }

    func tearDown() {
        drops.removeAll()
        pageAcceptsHandoff = false
        authHost?.tearDown()
    }

    // MARK: - drops

    /// Holds dropped files under a short-lived token the page can hand back with its request.
    func holdDrop(_ urls: [URL]) -> String? {
        pruneDrops()
        guard !urls.isEmpty else { return nil }
        let token = UUID().uuidString.lowercased()
        drops[token] = (urls, clock().addingTimeInterval(Self.dropLifetime))
        return token
    }

    /// Tells the page files were dropped. The card on screen takes them with its own choices; a
    /// drop anywhere else is a quick import.
    func announceDrop(token: String, in webView: WKWebView) {
        guard let eventLiteral = try? String(data: JSONSerialization.data(withJSONObject: [contract.drop, token]), encoding: .utf8) else { return }
        let js = "(([name, token]) => window.dispatchEvent(new CustomEvent(name, {detail: {token}, cancelable: true})))(\(eventLiteral));"
        webView.evaluateJavaScript(js, in: nil, in: .page) { _ in }
    }

    private func pruneDrops() {
        let now = clock()
        drops = drops.filter { $0.value.expires > now }
    }

    private func takeDrop(_ token: String) -> [URL]? {
        pruneDrops()
        return drops.removeValue(forKey: token)?.urls
    }

    // MARK: - requests

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        let sender = JournalImportSender(
            isMainFrame: message.frameInfo.isMainFrame,
            scheme: message.frameInfo.securityOrigin.protocol,
            host: message.frameInfo.securityOrigin.host,
            port: message.frameInfo.securityOrigin.port,
            isThisWebView: message.webView === webView
        )
        let body = message.body as? String
        Task { @MainActor in
            if let reply = await self.handle(body: body, from: sender) {
                replyHandler(reply, nil)
            } else {
                replyHandler(nil, "refused")
            }
        }
    }

    /// Answers one request from the page, or nil when it didn't come from the top journal
    /// document on the live origin.
    func handle(body: String?, from sender: JournalImportSender) async -> String? {
        guard sender.isMainFrame, sender.isThisWebView,
              let base = liveBaseURL(), let live = JournalWindowOrigin(url: base),
              sender.matches(live)
        else {
            importHostLog.notice("import-host: refused a message from outside the top journal document")
            return nil
        }
        guard let body, let data = body.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = message["type"] as? String
        else { return nil }
        switch type {
        case "host.ready":
            pageAcceptsHandoff = true
            return Self.encode([:])
        case "host.status":
            guard let item = message["item"] as? String, item.count <= Self.maxIDLength, let intake = intake() else {
                return Self.encode(["state": "gone"])
            }
            return Self.encode(Self.statusFields(await intake.handoffStatus(item)))
        case contract.pick:
            return Self.encode(await pick(message))
        default:
            if let authHost, authHost.handles(type: type) {
                return Self.encode(await authHost.handle(message, type: type))
            }
            let id = message["id"] as? String ?? ""
            return Self.encode(["type": contract.unsupported, "id": id])
        }
    }

    private func pick(_ message: [String: Any]) async -> [String: Any] {
        let id = message["id"] as? String ?? ""
        func reply(_ outcome: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            ["type": contract.reply, "id": id, "outcome": outcome].merging(extra) { a, _ in a }
        }
        guard let request = parsePick(message) else { return reply("refused") }
        guard !picking else { return reply("busy") }
        guard let intake = intake() else { return reply("refused") }
        picking = true
        defer { picking = false }
        let urls: [URL]
        if let token = request.dropToken {
            guard let dropped = takeDrop(token) else { return reply("refused") }
            urls = request.multiple ? dropped : Array(dropped.prefix(1))
        } else {
            let picker = JournalImportPickerRequest(types: Self.pickerTypes(request.accept), multiple: request.multiple)
            guard let chosen = await presentPicker(picker, webView?.window), !chosen.isEmpty else { return reply("cancelled") }
            urls = chosen
        }
        let result = await intake.addHandedOver(urls, handoff: request.handoff)
        var items: [[String: Any]] = []
        var refused: [[String: Any]] = []
        for entry in result.outcomes {
            switch entry.outcome {
            case .added(let item):
                items.append(["item": item, "name": entry.name])
            case .refused(let reason):
                refused.append(["name": entry.name, "reason": ImportCopy.refusal(reason)])
            }
        }
        importHostLog.notice("import-host: pick queued=\(items.count, privacy: .public) refused=\(refused.count, privacy: .public)")
        return reply(items.isEmpty ? "refused" : "queued", ["items": items, "refused": refused])
    }

    struct PickRequest: Equatable {
        var accept: [String]
        var multiple: Bool
        var handoff: ImportHandoff
        var dropToken: String?
    }

    /// A pick needs a string id, an area word, a list of filters and a context object that fits
    /// the contract's limit. Fields the contract doesn't name are ignored.
    func parsePick(_ message: [String: Any]) -> PickRequest? {
        guard let id = message["id"] as? String, !id.isEmpty, id.count <= Self.maxIDLength,
              let area = message["area"] as? String, Self.isAreaWord(area)
        else { return nil }
        let accept: [String]
        switch message["accept"] {
        case nil: accept = []
        case let list as [Any]:
            let strings = list.compactMap { $0 as? String }
            guard strings.count == list.count, strings.count <= Self.maxAcceptEntries,
                  strings.allSatisfy({ $0.count <= 128 }) else { return nil }
            accept = strings
        default: return nil
        }
        let multiple: Bool
        switch message["multiple"] {
        case nil: multiple = false
        case let flag as Bool: multiple = flag
        default: return nil
        }
        let contextObject: [String: Any]
        switch message["context"] {
        case nil: contextObject = [:]
        case let object as [String: Any]: contextObject = object
        default: return nil
        }
        guard let contextData = try? JSONSerialization.data(withJSONObject: contextObject, options: [.sortedKeys, .withoutEscapingSlashes]),
              contextData.count <= contract.contextMaxBytes,
              let context = String(data: contextData, encoding: .utf8)
        else { return nil }
        let dropToken: String?
        switch message["drop"] {
        case nil: dropToken = nil
        case let token as String where !token.isEmpty && token.count <= Self.maxIDLength: dropToken = token
        default: return nil
        }
        return PickRequest(accept: accept, multiple: multiple, handoff: ImportHandoff(area: area, context: context), dropToken: dropToken)
    }

    private static func isAreaWord(_ area: String) -> Bool {
        (1...64).contains(area.count) && area.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
        }
    }

    /// The page's filters as types the picker can show first. Extensions and MIME types map to
    /// their types, `image/*` and its kin to their families; anything else is left out.
    static func pickerTypes(_ accept: [String]) -> [UTType] {
        var types: [UTType] = []
        for raw in accept {
            let entry = raw.trimmingCharacters(in: .whitespaces).lowercased()
            let type: UTType?
            if entry.hasPrefix(".") {
                type = UTType(filenameExtension: String(entry.dropFirst()))
            } else if entry.hasSuffix("/*") {
                switch entry.dropLast(2) {
                case "image": type = .image
                case "audio": type = .audio
                case "video": type = .movie
                case "text": type = .text
                default: type = nil
                }
            } else if entry.contains("/") {
                type = UTType(mimeType: entry)
            } else {
                type = nil
            }
            if let type, !types.contains(type) { types.append(type) }
        }
        return types
    }

    static func statusFields(_ status: ImportHandoffStatus) -> [String: Any] {
        switch status {
        case .waiting: return ["state": "waiting"]
        case .uploading: return ["state": "uploading"]
        case .attention(let reason, let importID):
            var fields: [String: Any] = ["state": "attention", "reason": reason]
            if let importID { fields["import_id"] = importID }
            return fields
        case .delivered(let importID):
            var fields: [String: Any] = ["state": "delivered"]
            if let importID { fields["import_id"] = importID }
            return fields
        case .gone: return ["state": "gone"]
        }
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// The page half. Mirrors the reference host: one capability object on the top document,
    /// replies parsed from the native handler, item status read until it settles, and a drop no
    /// card claimed sent as a quick import.
    static let scriptBody = #"""
    (contract, origin, handler, auth) => {
      if (window !== window.top || location.origin !== origin) return;
      const native = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[handler];
      if (!native) return;
      const post = async message => JSON.parse(await native.postMessage(JSON.stringify(message)));
      const authTypes = auth ? [auth.prepare, auth.authorize, auth.cancel] : [];
      const types = Object.freeze([contract.pick, ...authTypes]);
      const items = new Map();
      let timer;
      async function update() {
        for (const [item, record] of items) {
          try {
            const status = await post({type: 'host.status', item});
            const serial = JSON.stringify(status);
            if (record.last !== serial) {
              record.last = serial;
              window.dispatchEvent(new CustomEvent(contract.event, {detail: {
                ...status, type: contract.status, item, name: record.name, id: record.id,
              }}));
            }
            if (['attention', 'delivered', 'gone'].includes(status.state)) items.delete(item);
          } catch (_) { /* Read it again while the document is open. */ }
        }
        timer = items.size ? setTimeout(update, 400) : undefined;
      }
      Object.defineProperty(window, contract.capability, {value: Object.freeze({
        version: contract.version, types,
        async send(message) {
          if (!message || typeof message.id !== 'string' || typeof message.type !== 'string') throw new TypeError();
          if (authTypes.includes(message.type)) return await post(message);
          if (message.type !== contract.pick) return {type: contract.unsupported, id: message.id};
          const reply = await post(message);
          for (const entry of reply.items || []) items.set(entry.item, {id: message.id, name: entry.name});
          if (items.size && !timer) timer = setTimeout(update, 0);
          return reply;
        }
      })});
      window.addEventListener(contract.drop, event => {
        queueMicrotask(() => {
          if (!event.defaultPrevented && event.detail && event.detail.token)
            window[contract.capability].send({type: contract.pick, id: crypto.randomUUID(), area: 'quick',
              accept: [], multiple: true, context: {}, drop: event.detail.token}).catch(() => {});
        });
      });
      document.addEventListener('DOMContentLoaded', () => {
        if (window.solstoneImportContract && window.solstoneImportContract.version === contract.version)
          post({type: 'host.ready'}).catch(() => {});
      }, {once: true});
    }
    """#
}

/// Who sent a message, as WebKit reports it.
struct JournalImportSender: Equatable, Sendable {
    var isMainFrame: Bool
    var scheme: String
    var host: String
    /// Zero when the origin uses its scheme's default port.
    var port: Int
    var isThisWebView: Bool

    func matches(_ origin: JournalWindowOrigin) -> Bool {
        let scheme = scheme.lowercased()
        let port = port == 0 ? (scheme == "https" ? 443 : 80) : port
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return scheme == origin.scheme && host == origin.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) && port == origin.port
    }
}

/// The open panel for a handoff. The page's filters narrow what it shows first; the owner can
/// switch to every file and pick anything.
@MainActor
enum JournalImportPicker {
    static func present(_ request: JournalImportPickerRequest, over window: NSWindow?) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = request.multiple
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        let chooser = JournalImportFilterChooser(panel: panel, types: request.types)
        if let accessory = chooser.accessoryView {
            panel.accessoryView = accessory
            panel.isAccessoryViewDisclosed = true
        }
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            if let window {
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }
        withExtendedLifetime(chooser) {}
        guard response == .OK else { return nil }
        return panel.urls
    }
}

/// The panel's show menu: the page's types, or every file.
@MainActor
private final class JournalImportFilterChooser: NSObject {
    private weak var panel: NSOpenPanel?
    private let types: [UTType]
    private(set) var accessoryView: NSView?

    init(panel: NSOpenPanel, types: [UTType]) {
        self.panel = panel
        self.types = types
        super.init()
        guard !types.isEmpty else { return }
        panel.allowedContentTypes = types
        var names: [String] = []
        for type in types {
            let name = type.localizedDescription ?? type.preferredFilenameExtension ?? type.identifier
            if !names.contains(name) { names.append(name) }
        }
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: [names.joined(separator: ", "), MacStrings.macos_journalimporthost_allfiles()])
        popup.target = self
        popup.action = #selector(choose(_:))
        popup.sizeToFit()
        let stack = NSStackView(views: [popup])
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        accessoryView = stack
    }

    @objc private func choose(_ sender: NSPopUpButton) {
        panel?.allowedContentTypes = sender.indexOfSelectedItem == 0 ? types : []
    }
}

/// The journal window's web view. Files dropped on it go to the app's import queue when the page
/// takes the handoff; otherwise the page handles the drop as it always has.
final class JournalDropWebView: WKWebView {
    weak var importHost: JournalImportHost?

    private func droppedFileURLs(_ info: any NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls ?? []
    }

    private func handlesDrop(_ info: any NSDraggingInfo) -> Bool {
        (importHost?.pageAcceptsHandoff ?? false) && !droppedFileURLs(info).isEmpty
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        handlesDrop(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        handlesDrop(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        handlesDrop(sender) ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard handlesDrop(sender) else { return super.performDragOperation(sender) }
        guard let host = importHost, let token = host.holdDrop(droppedFileURLs(sender)) else { return false }
        host.announceDrop(token: token, in: self)
        return true
    }
}
