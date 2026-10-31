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
        var pending = [window]
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
            AXUIElementSetMessagingTimeout(node, 0.025)

            var roleValue: CFTypeRef?
            let roleError = AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &roleValue)
            if roleError != .success && roleError != .noValue {
                return WebAreaWalkResult(urls: urls, completeness: .axError)
            }
            let role = roleValue as? String
            guard ![kAXTextFieldRole, kAXTextAreaRole, "AXToolbar", "AXButton",
                    "AXRadioButton", "AXImage", "AXMenuButton", "AXStaticText"].contains(role ?? "") else {
                continue
            }

            if role == "AXWebArea" {
                var urlValue: CFTypeRef?
                var urlString: String?
                let urlError = AXUIElementCopyAttributeValue(node, "AXURL" as CFString, &urlValue)
                if urlError == .success {
                    if let url = urlValue as? URL {
                        urlString = url.absoluteString
                    } else if let s = urlValue as? String {
                        urlString = s
                    }
                }
                urls.append(urlString)
                if mode == .firstDocument && urlString != nil {
                    return WebAreaWalkResult(urls: urls, completeness: .complete)
                }
                // Do not enter page contents.
                continue
            }

            var childrenValue: CFTypeRef?
            let childrenError = AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &childrenValue)
            if childrenError == .success, let elements = childrenValue as? [AXUIElement] {
                let capacityRemaining = max(0, 128 - pending.count)
                if elements.count > capacityRemaining {
                    hitCut = true
                }
                pending.append(contentsOf: elements.prefix(capacityRemaining).reversed())
            } else if childrenError != .success && childrenError != .noValue && childrenError != .attributeUnsupported {
                return WebAreaWalkResult(urls: urls, completeness: .axError)
            }
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
