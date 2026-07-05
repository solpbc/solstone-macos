// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

public struct JournalMarkPopAnimation: ViewModifier {
    private let generation: Int
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    public init(generation: Int) {
        self.generation = generation
    }

    public func body(content: Content) -> some View {
        content
            .id(generation)
            .transition(accessibilityReduceMotion ? .identity : Self.popTransition)
            .animation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.26), value: generation)
    }

    private static var popTransition: AnyTransition {
        .opacity
            .combined(with: .offset(y: 4))
            .combined(with: .scale(scale: 0.98, anchor: .center))
    }
}

public extension View {
    func journalMarkPop(generation: Int) -> some View {
        modifier(JournalMarkPopAnimation(generation: generation))
    }
}
