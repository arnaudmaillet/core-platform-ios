import Testing
import UIKit
@testable import DesignSystem

/// The navigation bar's leading selector (#2337): the room the bar leaves it,
/// 15pt or 13pt, a scroll past that, never less than one bubble — and an item
/// re-minted under one identifier when its width moves.
@MainActor
struct BarSelectorItemTests {
    private func strip() -> PagedTabBar {
        PagedTabBar(titles: ["Chats", "Requests", "Suggestions"], style: .navigationTitle)
    }

    // MARK: - The budget (the August arithmetic)

    /// The bell alone leaves 286pt on a 402pt bar and 259 on an iPhone SE:
    /// 16pt margins, a 48pt bubble and 12pt for the bell, 24pt kept at the
    /// trailing end. (The August 314 / 287 swept the group into a `•••` on
    /// iOS 27.)
    @Test func theBellAloneLeavesRoomWithTheTrailingReserve() {
        #expect(BarSelectorBudget(barWidth: 402, leadingWidths: [44]).room == 286)
        #expect(BarSelectorBudget(barWidth: 375, leadingWidths: [44]).room == 259)
        #expect(BarSelectorBudget(barWidth: 402).room == 346, "nothing to lead: the margins and the reserve")
    }

    /// A trailing group shares one pill: 44, then +27 per item, and 24pt
    /// between the two groups.
    @Test func aTrailingGroupIsChargedAsOnePill() {
        // ⚠️ The expected rooms are stated as typed constants, compared with a
        // tolerance: an arithmetic chain of literals inside `#expect`
        // compared unequal on CI ("246.0" against "246").
        let one = BarSelectorBudget(barWidth: 402, leadingWidths: [44], trailingWidths: [44])
        let oneRoom: CGFloat = 238 // 402 − 32 − 60 − 48 − 24
        #expect(abs(one.room - oneRoom) < 0.01, "\(one.room)")
        let two = BarSelectorBudget(barWidth: 402, leadingWidths: [44], trailingWidths: [44, 44])
        let twoRoom: CGFloat = 163 // 402 − 32 − 60 − (48 + 27 + 48) − 24
        #expect(abs(two.room - twoRoom) < 0.01, "\(two.room)")
        // A glyph narrower than a platter still takes one.
        #expect(BarSelectorBudget(barWidth: 402, leadingWidths: [20]).room == 286)
    }

    /// The ceiling leaves the platter's ring out, and never falls below one
    /// bubble — demanding more than the bar has is how a group becomes `•••`.
    @Test func theCeilingNeverFallsBelowABubble() {
        let roomy = BarSelectorBudget(barWidth: 402, leadingWidths: [44])
        #expect(roomy.selectorCeiling(bubble: 44, ring: 4) == 278)
        let cramped = BarSelectorBudget(barWidth: 160, leadingWidths: [44], trailingWidths: [44, 44])
        #expect(cramped.selectorCeiling(bubble: 44, ring: 4) == 44)
    }

    // MARK: - The strip

    /// 13pt is narrower than 15pt, measured without switching.
    @Test func compactTitlesAreNarrower() {
        let bar = strip()
        bar.setBadge(43, at: 0)
        bar.setBadge(6, at: 1)
        let regular = bar.preferredWidth(at: .regular)
        let compact = bar.preferredWidth(at: .compact)
        #expect(compact < regular)
        #expect(bar.titleSize == .regular, "measuring switched the titles")
        #expect(abs(bar.intrinsicContentSize.width - regular) < 0.5)
        bar.titleSize = .compact
        #expect(abs(bar.intrinsicContentSize.width - compact) < 0.5)
    }

    /// A ceiling caps the stated width; the strip scrolls under it.
    @Test func aCeilingCapsTheStatedWidth() {
        let bar = strip()
        let wanted = bar.intrinsicContentSize.width
        bar.widthCeiling = 120
        #expect(bar.intrinsicContentSize.width == 120)
        bar.widthCeiling = nil
        #expect(bar.intrinsicContentSize.width == wanted)
    }

    // MARK: - The item

    /// 15pt when the titles fit, 13pt when only 13pt fits, and past that the
    /// ceiling: the strip scrolls.
    @Test func fitPicksFifteenThenThirteenThenScrolls() {
        let bar = strip()
        let selector = BarSelectorItem(strip: bar, id: "test.selector")
        let ring = bar.hosting.overhang
        let regular = bar.preferredWidth(at: .regular)
        let compact = bar.preferredWidth(at: .compact)

        // Room for 15pt.
        let fixed = BarSelectorBudget.barMargin * 2 + BarSelectorBudget.trailingReserve
        selector.fit(BarSelectorBudget(barWidth: regular + ring * 2 + fixed + 10))
        #expect(bar.titleSize == .regular)
        #expect(abs(bar.intrinsicContentSize.width - regular) < 0.5)

        // Room for 13pt only.
        selector.fit(BarSelectorBudget(barWidth: compact + ring * 2 + fixed + 1))
        #expect(bar.titleSize == .compact)
        #expect(abs(bar.intrinsicContentSize.width - compact) < 0.5)

        // Not even that: capped, never below a bubble.
        selector.fit(BarSelectorBudget(barWidth: 120))
        #expect(bar.titleSize == .compact)
        #expect(bar.intrinsicContentSize.width < compact)
        #expect(bar.intrinsicContentSize.width >= bar.intrinsicContentSize.height)
    }

    /// ONE item for the strip's life, as For You's: a width change is told
    /// in place (`fit` answers that it moved), never by minting a new item
    /// around the same strip — a strip handed from one item to the next lost
    /// its window (`-pill-drag-probe` read `bar=0`).
    @Test func aWidthChangeKeepsTheOneItem() throws {
        let bar = strip()
        let selector = BarSelectorItem(strip: bar, id: "test.selector")
        let first = selector.item
        let budget = BarSelectorBudget(barWidth: 402, leadingWidths: [44])
        #expect(selector.fit(budget), "the first fit states a width")
        #expect(!selector.fit(budget), "the same room moved the width")

        bar.setBadge(43, at: 0)
        #expect(selector.fit(budget), "a count did not move the width")
        #expect(selector.item === first, "the item was re-minted")
        #expect(selector.item.identifier == "test.selector")
        #expect(selector.item.customView === bar)
    }

    /// A bar that swept the group anyway: each narrowing takes a step off
    /// the ceiling and mints a fresh item under the same identifier around
    /// the same strip, down to one bubble and no further.
    @Test func aSweptSelectorNarrowsDownToABubble() {
        let bar = strip()
        let selector = BarSelectorItem(strip: bar, id: "test.selector")
        let budget = BarSelectorBudget(barWidth: 402, leadingWidths: [44])
        selector.fit(budget)
        #expect(!selector.isHosted, "no window, no bar")
        let first = selector.item
        let before = selector.ceiling(for: budget)
        #expect(selector.narrowAfterOverflow(budget))
        #expect(selector.ceiling(for: budget) == before - BarSelectorItem.trimStep)
        #expect(selector.item !== first)
        #expect(selector.item.identifier == "test.selector" && selector.item.customView === bar)
        var steps = 1
        while selector.narrowAfterOverflow(budget), steps < 50 { steps += 1 }
        #expect(steps < 50, "it never stopped narrowing")
        #expect(abs(selector.ceiling(for: budget) - bar.intrinsicContentSize.height) < 0.5)
        #expect(bar.intrinsicContentSize.width >= bar.intrinsicContentSize.height - 0.5)
    }

    /// `[lead][separator][selector]`, or the selector alone; the same
    /// separator every time, so an unchanged group compares identical.
    @Test func theLeadingGroup() {
        let selector = BarSelectorItem(strip: strip(), id: "test.selector")
        let bell = UIBarButtonItem(customView: UIView())
        let group = selector.leadingGroup(after: bell)
        #expect(group.count == 3 && group[0] === bell && group[2] === selector.item)
        #expect(selector.leadingGroup(after: bell)[1] === group[1])
        #expect(selector.leadingGroup(after: nil).count == 1)
        #expect(selector.strip.hosting == .platter)
    }
}
