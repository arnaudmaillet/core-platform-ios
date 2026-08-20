import Testing
import UIKit
@testable import DesignSystem

/// The rule the leading selector's width is decided by: **the toolbar never
/// collapses**.
///
/// UIKit's own answer to a bar whose items do not fit is to sweep a group into a
/// `•••`, and it takes the actions with it — on iPhone SE 3 that was the whole
/// Messages header, and the profile's two trailing actions. So the selector is
/// the last claim on the width: everything else is charged first, and the capsule
/// takes the remainder, down to a bubble.
///
/// Every constant here was measured on a 375pt bar with `-header-bar-tree`, and
/// the thresholds below are the ones the platters actually showed. They live here
/// rather than in each screen because the number used to be hand-tuned per
/// surface (the inbox's `roomForOtherItems: 110`) and a constant tuned against
/// two devices is already wrong for the third.
struct LeadingSelectorBudgetTests {
    /// The narrowest phone the app supports, and the one the collapse was
    /// reported on.
    private static let iPhoneSE3: CGFloat = 375
    private static let iPhone17Pro: CGFloat = 402

    /// A `.navigationTitle` bar stands 44pt tall, so its bubble is 44 across.
    private static let bubble = PagedTabBar.Style.navigationTitle.height

    private func budget(
        _ barWidth: CGFloat, leading: [CGFloat] = [], trailing: [CGFloat] = []
    ) -> LeadingSelectorBudget {
        LeadingSelectorBudget(
            barWidth: barWidth, leadingSiblingWidths: leading, trailingWidths: trailing
        )
    }

    /// The inbox: selector alone in the leading group, one trailing magnifier.
    /// Measured on a 375pt bar — hosted at a 267pt ceiling (platter 16…291,
    /// magnifier at 315), collapsed at the uncapped 280.
    @Test func theInboxClearsTheMeasuredCliffOnTheNarrowestPhone() {
        let ceiling = budget(Self.iPhoneSE3, trailing: [44]).ceiling(bubbleWidth: Self.bubble)
        #expect(ceiling == 267)
    }

    /// The other half of that bind: on a normal phone the same bar must NOT be
    /// clipped. Its three titles want 259pt, and the old hand-tuned constant
    /// granted 220 — "Suggestions" cut off mid-word with room going spare.
    @Test func theInboxTakesItsFullWidthWhereThereIsRoomForIt() {
        let ceiling = budget(Self.iPhone17Pro, trailing: [44]).ceiling(bubbleWidth: Self.bubble)
        #expect(ceiling >= 259)
    }

    /// The profile, docked: five tabs, two trailing actions in ONE shared pill.
    /// Measured on 375 — the pair survives at a 200pt ceiling (pill 244…359) and
    /// becomes a `•••` at 215, so the budget has to land at or under 200.
    @Test func theProfilesTrailingPairSurvivesOnTheNarrowestPhone() {
        let ceiling = budget(Self.iPhoneSE3, trailing: [44, 44]).ceiling(bubbleWidth: Self.bubble)
        #expect(ceiling <= 200)
        // Not so conservative that five tabs become a stub: the capsule still
        // shows two whole titles and scrolls for the rest.
        #expect(ceiling >= 170)
    }

    /// ⚠️ The trap that made the profile collapse: a second item in the trailing
    /// group costs MORE than a platter, because the two share one pill and the
    /// pill is 115pt wide rather than 88.
    @Test func aSecondTrailingItemCostsMoreThanItsOwnWidth() {
        let one = budget(Self.iPhoneSE3, trailing: [44]).roomForOtherItems
        let two = budget(Self.iPhoneSE3, trailing: [44, 44]).roomForOtherItems
        #expect(two - one == 44 + LeadingSelectorBudget.sharedItemSpacing)
        #expect(two - one > LeadingSelectorBudget.itemWidth)
    }

    /// For You carries a compose glyph in the leading group beside the selector.
    /// A leading sibling gets its OWN platter — the selector's does not share a
    /// background — so it is charged the platter gap, not the pill's spacing.
    @Test func aLeadingSiblingIsChargedItsOwnPlatter() {
        let alone = budget(Self.iPhoneSE3, trailing: [44]).roomForOtherItems
        let paired = budget(Self.iPhoneSE3, leading: [44], trailing: [44]).roomForOtherItems
        #expect(paired - alone == 44 + LeadingSelectorBudget.platterGap)
    }

    /// A bar with nothing trailing is not charged the gap between the two groups
    /// — there is no second group to keep clear of. Measured: with the magnifier
    /// removed the inbox's capsule took its full 280 on a 375pt bar.
    @Test func anEmptyTrailingGroupCostsNoGap() {
        let bare = budget(Self.iPhoneSE3).roomForOtherItems
        #expect(bare == LeadingSelectorBudget.barMargin * 2 + LeadingSelectorBudget.platterPadding)
        #expect(budget(Self.iPhoneSE3).ceiling(bubbleWidth: Self.bubble) >= 280)
    }

    /// A titled action — the profile's Follow capsule — is charged what it wants,
    /// not the 44pt a glyph costs.
    @Test func aWideItemIsChargedItsOwnWidth() {
        let glyphs = budget(Self.iPhone17Pro, trailing: [44, 44]).roomForOtherItems
        let titled = budget(Self.iPhone17Pro, trailing: [96, 44]).roomForOtherItems
        let difference: CGFloat = 96 - 44
        #expect(titled - glyphs == difference)
    }

    /// And a NARROW item is still charged the platter's 44: UIKit will not draw
    /// one smaller than the touch target however small the glyph inside it.
    @Test func aNarrowItemIsStillChargedAWholePlatter() {
        #expect(budget(Self.iPhone17Pro, trailing: [20]).roomForOtherItems
                == budget(Self.iPhone17Pro, trailing: [44]).roomForOtherItems)
    }

    /// The floor, and the user-visible shape of it: crowd the bar with actions
    /// and the selector becomes a perfect circle — as wide as it is tall — rather
    /// than a stub, and never a `•••`.
    @Test func aCrowdedBarLeavesABubbleAndNeverLessThanOne() {
        let four = budget(Self.iPhoneSE3, trailing: Array(repeating: 44, count: 4))
        #expect(four.ceiling(bubbleWidth: Self.bubble) > Self.bubble)
        // A fifth takes the subtraction under the bubble, and the floor holds it
        // AT the bubble rather than at the negative number.
        let five = budget(Self.iPhoneSE3, trailing: Array(repeating: 44, count: 5))
        #expect(five.barWidth - five.roomForOtherItems < Self.bubble)
        #expect(five.ceiling(bubbleWidth: Self.bubble) == Self.bubble)
    }

    /// The pathological case, stated so the behaviour is a decision and not an
    /// accident: even a bar narrower than its own margins yields a bubble. A
    /// negative ceiling would give the item a zero size, and a zero-sized custom
    /// view is one UIKit declines to host at all.
    @Test func anImpossiblyNarrowBarStillYieldsABubble() {
        #expect(budget(120, trailing: [44, 44]).ceiling(bubbleWidth: Self.bubble) == Self.bubble)
        #expect(budget(0).ceiling(bubbleWidth: Self.bubble) == Self.bubble)
    }

    /// Wider screens hand the whole difference to the selector — nothing else on
    /// the bar grows, so nothing else should take a share of it.
    @Test func extraScreenWidthGoesEntirelyToTheSelector() {
        let narrow = budget(Self.iPhoneSE3, trailing: [44]).ceiling(bubbleWidth: Self.bubble)
        let wide = budget(Self.iPhone17Pro, trailing: [44]).ceiling(bubbleWidth: Self.bubble)
        #expect(wide - narrow == Self.iPhone17Pro - Self.iPhoneSE3)
    }
}
