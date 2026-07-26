// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import solstone

@Suite("Menubar Icon Overlay State")
struct MenubarIconOverlayStateTests {
    @Test func axTokensMatchContractVocabulary() {
        let cases: [(MenubarIconOverlayState, String)] = [
            (.none, "none"),
            (.attention, "attention"),
            (.chatPending, "chat_pending"),
        ]

        #expect(cases.count == MenubarIconOverlayState.allCases.count)
        for (state, token) in cases {
            #expect(state.axToken == token)
        }
    }

    @Test func overlayAXTokensAreInjective() {
        assertInjective(
            MenubarIconOverlayState.allCases,
            by: \.axToken,
            projectionName: "overlay AX token"
        )
    }

    @Test func overlayBadgeTreatmentsAreInjective() {
        assertInjective(
            MenubarIconOverlayState.allCases,
            by: \.badgeTreatment,
            projectionName: "overlay badge treatment"
        )
    }

    @Test func menubarIconAssetNamesAreInjective() {
        assertInjective(
            MenubarIconState.allCases,
            by: \.iconName,
            projectionName: "icon asset name"
        )
    }

    @Test func renderedMeaningCrossProductMatchesContract() {
        let attentionOptions: [AttentionReason?] = [nil] + AttentionReason.allCases.map(Optional.some)
        let messageOptions: [MenubarMessage?] = [nil, .chatPending]
        var checked = 0

        for rowState in MenubarStatusRowState.allCases {
            for attention in attentionOptions {
                for message in messageOptions {
                    let presentation = MenubarPresentation(
                        observation: rowState,
                        attention: attention,
                        message: message
                    )
                    let expectedOverlay: MenubarIconOverlayState = attention != nil
                        ? .attention
                        : (message == nil ? .none : .chatPending)

                    #expect(presentation.icon == rowState.iconState)
                    #expect(presentation.overlayState == expectedOverlay)
                    checked += 1
                }
            }
        }

        #expect(checked == MenubarStatusRowState.allCases.count * (AttentionReason.allCases.count + 1) * (MenubarMessage.allCases.count + 1))
    }

    @Test func badgeTreatmentsMatchApprovedGeometry() {
        #expect(MenubarIconOverlayState.none.badgeTreatment == nil)
        #expect(MenubarIconOverlayState.attention.badgeTreatment == MenubarBadgeTreatment(
            haloDiameter: 9.6,
            haloTint: .adaptiveInk,
            mark: .symbol(name: "exclamationmark.circle.fill", pointSize: 8, tint: .solOrange)
        ))
        #expect(MenubarIconOverlayState.chatPending.badgeTreatment == MenubarBadgeTreatment(
            haloDiameter: 7.6,
            haloTint: .adaptiveInk,
            mark: .dot(diameter: 6, tint: .accentColor)
        ))
    }

    @Test func solOrangeComponentsMatchCanonicalHex() {
        #expect(SolstoneColors.solOrangeComponents == SRGBAColorComponents(
            red: 232.0 / 255.0,
            green: 146.0 / 255.0,
            blue: 58.0 / 255.0,
            alpha: 1.0
        ))
    }
}

private func assertInjective<Element: Equatable, Projection: Equatable>(
    _ elements: [Element],
    by projection: (Element) -> Projection,
    projectionName: String
) {
    for lhsIndex in elements.indices {
        for rhsIndex in elements.indices where lhsIndex != rhsIndex {
            let lhs = elements[lhsIndex]
            let rhs = elements[rhsIndex]
            #expect(
                projection(lhs) != projection(rhs),
                "\(projectionName) collision between \(String(describing: lhs)) and \(String(describing: rhs))"
            )
        }
    }
}
