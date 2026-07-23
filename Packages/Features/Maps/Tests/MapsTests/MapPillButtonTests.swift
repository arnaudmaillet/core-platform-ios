import Testing
import UIKit
@testable import Maps

/// The pill's width contract: content-sized, but never past the cap that
/// keeps one overlong display name from eating the whole filter bar.
///
/// These run windowless on purpose — that's also the path where the Liquid
/// Glass material is never materialized (the CI doctrine), so sizing is
/// measured against the plain configuration.
@MainActor
struct MapPillButtonTests {
    private static func content(title: String?, expandsWhenSelected: Bool = false) -> MapPillButton.Content {
        MapPillButton.Content(
            title: title,
            symbolName: "person.crop.circle", selectedSymbolName: "person.crop.circle.fill",
            accessibilityLabel: title ?? "icon",
            expandsWhenSelected: expandsWhenSelected
        )
    }

    /// Resolves the pill's laid-out width. Measured inside a plain container
    /// (never a window — that would materialize the glass material) and by
    /// running the engine rather than `systemLayoutSizeFitting`, which
    /// reports the bare content size and skips the pill's own height / circle
    /// / cap constraints.
    private static func width(of button: MapPillButton) -> CGFloat {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 100))
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.topAnchor.constraint(equalTo: container.topAnchor)
        ])
        container.layoutIfNeeded()
        return button.frame.width
    }

    @Test func capIsHalfTheScreenUntilTheCeiling() {
        // Small phone: half the screen is the binding rule…
        #expect(MapPillButton.maxWidth(forScreenWidth: 320) == 160)
        // …a 402pt phone lands just past the ceiling, which then binds…
        #expect(MapPillButton.maxWidth(forScreenWidth: 402) == MapPillButton.widthCeiling)
        // …and an iPad never mints a banner.
        #expect(MapPillButton.maxWidth(forScreenWidth: 1024) == MapPillButton.widthCeiling)
    }

    @Test func longTitleIsCappedNotStretched() {
        let pill = MapPillButton(
            content: Self.content(title: "Maximilian Schwarzenberger-Ulrichsdottir the Third"),
            height: 36
        )
        #expect(Self.width(of: pill) <= MapPillButton.widthCeiling)
    }

    @Test func ordinaryTitleStaysIntrinsic() {
        // The cap must be inert for real names — pills stay content-sized.
        let pill = MapPillButton(content: Self.content(title: "Ava"), height: 36)
        let width = Self.width(of: pill)
        #expect(width > 0)
        #expect(width < MapPillButton.widthCeiling)
    }

    @Test func circularPillIsUnaffectedByTheCap() {
        // Title-less pills stay perfect circles: width == height, far below
        // the cap, so the two constraints can never fight.
        let pill = MapPillButton(content: Self.content(title: nil), height: 36)
        #expect(Self.width(of: pill) == 36)
    }

    @Test func morphingPillRestsCircularAndExpandsWithinTheCap() {
        // The morph endpoints: a 36pt circle at rest, an icon + title capsule
        // when selected — the expansion still obeys the cap.
        let pill = MapPillButton(
            content: Self.content(
                title: "Following Maximilian Schwarzenberger-Ulrichsdottir",
                expandsWhenSelected: true
            ),
            height: 36
        )
        #expect(Self.width(of: pill) == 36)

        pill.setSelectedAppearance(true)
        let expanded = Self.width(of: pill)
        #expect(expanded > 36)
        #expect(expanded <= MapPillButton.widthCeiling)
    }
}
