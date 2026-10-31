// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import ApplicationServices
import Foundation

public enum WebAreaWalkMode: Sendable, Equatable {
    case firstDocument
    case everyTopLevel
}

public struct WebAreaWalkResult: Sendable, Equatable {
    public enum Completeness: String, Sendable, Equatable {
        case complete
        case timedOut
        case axError
        case childListCut
    }

    public var urls: [String?]
    public var completeness: Completeness

    public init(urls: [String?], completeness: Completeness) {
        self.urls = urls
        self.completeness = completeness
    }
}

public enum WebAreaWalker {
    public struct TestNode: Sendable {
        public var roleFailed: Bool
        public var role: String?
        public var childrenFailed: Bool
        public var children: [Int]
        public var url: String?

        public init(
            roleFailed: Bool = false,
            role: String? = nil,
            childrenFailed: Bool = false,
            children: [Int] = [],
            url: String? = nil
        ) {
            self.roleFailed = roleFailed
            self.role = role
            self.childrenFailed = childrenFailed
            self.children = children
            self.url = url
        }
    }

    public static func walk(
        nodes: [TestNode],
        mode: WebAreaWalkMode
    ) -> WebAreaWalkResult {
        guard !nodes.isEmpty else {
            return WebAreaWalkResult(urls: [], completeness: .complete)
        }
        return walkTree(
            root: 0,
            mode: mode,
            permit: nil,
            role: { idx in
                guard idx >= 0 && idx < nodes.count else { return (failed: true, role: nil) }
                let n = nodes[idx]
                return (failed: n.roleFailed, role: n.role)
            },
            children: { idx in
                guard idx >= 0 && idx < nodes.count else { return (failed: true, children: []) }
                let n = nodes[idx]
                return (failed: n.childrenFailed, children: n.children)
            },
            url: { idx in
                guard idx >= 0 && idx < nodes.count else { return nil }
                return nodes[idx].url
            }
        )
    }

    public static func walk(
        _ window: AXUIElement,
        mode: WebAreaWalkMode
    ) -> WebAreaWalkResult {
        walk(window, mode: mode, permit: nil)
    }

    internal static func walk(
        _ window: AXUIElement,
        mode: WebAreaWalkMode,
        permit: DesktopActivityReadPermit?
    ) -> WebAreaWalkResult {
        walkTree(
            root: window,
            mode: mode,
            permit: permit,
            role: { node in
                AXUIElementSetMessagingTimeout(node, 0.025)
                var roleValue: CFTypeRef?
                let roleError = AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &roleValue)
                if roleError != .success && roleError != .noValue {
                    return (failed: true, role: nil)
                }
                return (failed: false, role: roleValue as? String)
            },
            children: { node in
                var childrenValue: CFTypeRef?
                let childrenError = AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &childrenValue)
                if childrenError == .success, let elements = childrenValue as? [AXUIElement] {
                    return (failed: false, children: elements)
                } else if childrenError != .success && childrenError != .noValue && childrenError != .attributeUnsupported {
                    return (failed: true, children: [])
                }
                return (failed: false, children: [])
            },
            url: { node in
                var urlValue: CFTypeRef?
                let urlError = AXUIElementCopyAttributeValue(node, "AXURL" as CFString, &urlValue)
                if urlError == .success {
                    if let url = urlValue as? URL {
                        return url.absoluteString
                    } else if let s = urlValue as? String {
                        return s
                    }
                }
                return nil
            }
        )
    }

    internal static func walkTree<Node>(
        root: Node,
        mode: WebAreaWalkMode,
        permit: DesktopActivityReadPermit?,
        role: (Node) -> (failed: Bool, role: String?),
        children: (Node) -> (failed: Bool, children: [Node]),
        url: (Node) -> String?
    ) -> WebAreaWalkResult {
        var pending = [root]
        var visited = 0
        var urls: [String?] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        var hitCut = false

        while (permit?.isValid ?? true) && !pending.isEmpty && visited < 128 {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                return WebAreaWalkResult(urls: urls, completeness: .timedOut)
            }
            let node = pending.removeLast()
            visited += 1

            let roleRes = role(node)
            if roleRes.failed {
                if mode == .everyTopLevel {
                    return WebAreaWalkResult(urls: urls, completeness: .axError)
                }
                continue
            }
            let roleStr = roleRes.role
            guard ![kAXTextFieldRole, kAXTextAreaRole, "AXToolbar", "AXButton",
                    "AXRadioButton", "AXImage", "AXMenuButton", "AXStaticText"].contains(roleStr ?? "") else {
                continue
            }

            if roleStr == "AXWebArea" {
                let urlString = url(node)
                urls.append(urlString)
                if mode == .firstDocument && urlString != nil {
                    return WebAreaWalkResult(urls: urls, completeness: .complete)
                }
                // Do not enter page contents.
                continue
            }

            let childrenRes = children(node)
            if childrenRes.failed {
                if mode == .everyTopLevel {
                    return WebAreaWalkResult(urls: urls, completeness: .axError)
                }
                continue
            }
            let elements = childrenRes.children
            let capacityRemaining = max(0, 128 - pending.count)
            if elements.count > capacityRemaining {
                hitCut = true
            }
            pending.append(contentsOf: elements.prefix(capacityRemaining).reversed())
        }

        let completeness: WebAreaWalkResult.Completeness
        if visited >= 128 || hitCut {
            completeness = .childListCut
        } else {
            completeness = .complete
        }
        return WebAreaWalkResult(urls: urls, completeness: completeness)
    }
}
