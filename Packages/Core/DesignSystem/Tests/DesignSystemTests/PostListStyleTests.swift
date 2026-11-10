import Testing
import UIKit
@testable import DesignSystem

/// The flat post lists' A/B (#2243): which style a launch asks for, and the
/// ground each style lays its posts on.
@MainActor
struct PostListStyleTests {
    private let light = UITraitCollection(userInterfaceStyle: .light)
    private let dark = UITraitCollection(userInterfaceStyle: .dark)

    /// Without the argument and without the switch: today's cards, unchanged.
    @Test func theDefaultIsTodaysCards() {
        #expect(PostListStyle.resolve(arguments: ["app"], switchedOn: { false }) == .cards)
    }

    /// The valued argument decides, whatever the dashboard's switch says —
    /// a QA run can ask for either style.
    @Test func theArgumentsValueWins() {
        #expect(PostListStyle.resolve(arguments: ["app", "-post-list-style", "flat"], switchedOn: { false }) == .flat)
        #expect(PostListStyle.resolve(arguments: ["app", "-post-list-style", "cards"], switchedOn: { true }) == .cards)
    }

    /// A bare flag, or one followed by another argument, means flat — the
    /// dashboard switch's meaning.
    @Test func aBareFlagIsFlat() {
        #expect(PostListStyle.resolve(arguments: ["app", "-post-list-style"], switchedOn: { false }) == .flat)
        #expect(PostListStyle.resolve(arguments: ["app", "-post-list-style", "-other"], switchedOn: { false }) == .flat)
    }

    /// Without the argument, the persisted switch stands in for it.
    @Test func theSwitchStandsInForTheArgument() {
        #expect(PostListStyle.resolve(arguments: ["app"], switchedOn: { true }) == .flat)
    }

    /// The switch is listed, so the dashboard offers it — and the guard in
    /// `DebugFlagsTests` holds it to being read through `DebugFlags.isOn`.
    @Test func theDashboardOffersTheSwitch() {
        let flag = DebugFlags.all.first { $0.argument == PostListStyle.argument }
        #expect(flag != nil)
        #expect(flag?.appliesAtLaunch == true, "the style is read once, at launch")
    }

    /// The page's ground per style: the grouped grey under cards, the plain
    /// white under flat rows — and the two are one black in the dark.
    @Test func thePageGroundPerStyle() {
        #expect(PostListStyle.cards.pageGround.resolvedColor(with: light) == Surface.page.resolvedColor(with: light))
        #expect(PostListStyle.flat.pageGround.resolvedColor(with: light)
            == UIColor.systemBackground.resolvedColor(with: light))
        #expect(PostListStyle.flat.pageGround.resolvedColor(with: light)
            != PostListStyle.cards.pageGround.resolvedColor(with: light))
        #expect(PostListStyle.flat.pageGround.resolvedColor(with: dark)
            == PostListStyle.cards.pageGround.resolvedColor(with: dark))
    }

    /// A card on the flat page stays distinct from it: a white card on white
    /// would have no edge in the light.
    @Test func aCardStaysDistinctOnTheFlatPage() {
        #expect(PostListStyle.cards.cardFill == Surface.card)
        #expect(PostListStyle.flat.cardFill.resolvedColor(with: light)
            != PostListStyle.flat.pageGround.resolvedColor(with: light))
        #expect(PostListStyle.flat.cardFill.resolvedColor(with: dark) == Surface.card.resolvedColor(with: dark))
    }
}
