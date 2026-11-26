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

    /// A trailing group shares one pill: 44, then +27 per item, and iOS 26's
    /// 24pt between the two groups.
    @Test func aTrailingGroupIsChargedAsOnePill() {
        // ⚠️ The expected rooms are stated as typed constants, compared with a
        // tolerance: an arithmetic chain of literals inside `#expect`
        // compared unequal on CI ("246.0" against "246").
        let one = BarSelectorBudget(barWidth: 402, leadingWidths: [44], trailingWidths: [44], interGroupGap: 24)
        let oneRoom: CGFloat = 238 // 402 − 32 − 60 − 48 − 24
        #expect(abs(one.room - oneRoom) < 0.01, "\(one.room)")
        let two = BarSelectorBudget(barWidth: 402, leadingWidths: [44], trailingWidths: [44, 44], interGroupGap: 24)
        let twoRoom: CGFloat = 163 // 402 − 32 − 60 − (48 + 27 + 48) − 24
        #expect(abs(two.room - twoRoom) < 0.01, "\(two.room)")
        // A glyph narrower than a platter still takes one.
        #expect(BarSelectorBudget(barWidth: 402, leadingWidths: [20]).room == 286)
    }

    /// #2577: where UIKit lets the selector run to the leading spacing before
    /// the trailing group (iOS 27, the probe), the budget leaves the SAME gap
    /// on each side of it — and the bar's width is spent exactly: margin,
    /// bell, gap, selector, gap, compose, margin.
    @Test(arguments: [CGFloat(402), 375])
    func theBudgetLeavesTheSameGapOnEachSideOfTheSelector(barWidth: CGFloat) {
        let budget = BarSelectorBudget(
            barWidth: barWidth, leadingWidths: [44], trailingWidths: [44],
            interGroupGap: BarSelectorBudget.leadingGap
        )
        #expect(budget.balancesGaps)
        #expect(budget.trailingGap == BarSelectorBudget.leadingGap)
        let spent = BarSelectorBudget.barMargin * 2 + BarSelectorBudget.platter * 2
            + BarSelectorBudget.leadingGap + budget.room + budget.trailingGap
        #expect(abs(spent - barWidth) < 0.01, "\(spent) of \(barWidth)")
    }

    /// iOS 26 keeps 24pt before the trailing group (not measured locally):
    /// no balance there, which would sweep the group into a `•••`. Nor
    /// without a bell or a trailing group: there is no second gap.
    @Test func noBalanceWhereUIKitKeepsMoreThanTheLeadingSpacing() {
        #expect(!BarSelectorBudget(barWidth: 402, leadingWidths: [44], trailingWidths: [44], interGroupGap: 24)
            .balancesGaps)
        #expect(!BarSelectorBudget(barWidth: 402, leadingWidths: [44], interGroupGap: 12).balancesGaps)
        #expect(!BarSelectorBudget(barWidth: 402, trailingWidths: [44], interGroupGap: 12).balancesGaps)
        // Without a trailing group the bar's own reserve applies.
        #expect(BarSelectorBudget(barWidth: 402, leadingWidths: [44], interGroupGap: 12).trailingGap
            == BarSelectorBudget.trailingReserve)
    }

    /// The ceiling leaves the platter's ring out, and never falls below one
    /// bubble — demanding more than the bar has is how a group becomes `•••`.
    @Test func theCeilingNeverFallsBelowABubble() {
        let roomy = BarSelectorBudget(barWidth: 402, leadingWidths: [44])
        #expect(roomy.selectorCeiling(bubble: 44, ring: 4) == 278)
        let cramped = BarSelectorBudget(barWidth: 160, leadingWidths: [44], trailingWidths: [44, 44])
        #expect(cramped.selectorCeiling(bubble: 44, ring: 4) == 44)
    }

    /// A balance measured under one budget holds under a close one — the
    /// bell's glyph swapped for its badged variant, a point wider — and not
    /// under a new text size (the bell 48 → 88pt) or a new bar width.
    @Test func aBalanceHoldsOnlyWhileTheBudgetStaysClose() {
        let measured = BarSelectorBudget(barWidth: 402, leadingWidths: [48], trailingWidths: [48])
        #expect(measured.isClose(to: BarSelectorBudget(barWidth: 402, leadingWidths: [49], trailingWidths: [48])))
        #expect(!measured.isClose(to: BarSelectorBudget(barWidth: 402, leadingWidths: [88], trailingWidths: [48])))
        #expect(!measured.isClose(to: BarSelectorBudget(barWidth: 375, leadingWidths: [48], trailingWidths: [48])))
        #expect(!measured.isClose(to: BarSelectorBudget(barWidth: 402, leadingWidths: [48])))
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

        // Room for 15pt: the platter still runs to the room (#2577).
        let fixed = BarSelectorBudget.barMargin * 2 + BarSelectorBudget.trailingReserve
        let roomy = BarSelectorBudget(barWidth: regular + ring * 2 + fixed + 10)
        selector.fit(roomy)
        #expect(bar.titleSize == .regular)
        #expect(abs(bar.intrinsicContentSize.width - selector.ceiling(for: roomy)) < 0.5)
        #expect(bar.intrinsicContentSize.width >= regular)

        // Room for 13pt only.
        let tight = BarSelectorBudget(barWidth: compact + ring * 2 + fixed + 1)
        selector.fit(tight)
        #expect(bar.titleSize == .compact)
        #expect(abs(bar.intrinsicContentSize.width - selector.ceiling(for: tight)) < 0.5)
        #expect(bar.intrinsicContentSize.width >= compact)

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

        // The platter fills the room (#2577): a count no longer moves it, a
        // narrower bar does.
        bar.setBadge(43, at: 0)
        #expect(!selector.fit(budget), "a count moved a platter that fills the room")
        let narrower = BarSelectorBudget(barWidth: 375, leadingWidths: [44])
        #expect(selector.fit(narrower), "a narrower bar did not move the width")
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

    /// #2577: titles that need less than the room — the platter still runs
    /// to it, the segments keep the widths they ask for, and the row is
    /// centred: the slack lands as equal end margins inside the capsule,
    /// never as a stretched segment.
    @Test func thePlatterFillsTheRoomWhenItsTitlesNeedLess() {
        let bar = PagedTabBar(titles: ["Chats", "Requests"], style: .navigationTitle)
        let selector = BarSelectorItem(strip: bar, id: "test.selector")
        let budget = BarSelectorBudget(barWidth: 402, leadingWidths: [44])
        selector.fit(budget)
        let width = bar.intrinsicContentSize.width
        #expect(abs(width - selector.ceiling(for: budget)) < 0.5)
        #expect(bar.preferredWidth(at: bar.titleSize) < width - 40, "the titles fill the room already")

        bar.frame = CGRect(x: 0, y: 0, width: width, height: bar.intrinsicContentSize.height)
        bar.layoutIfNeeded()
        let frames = bar.debugSegmentFrames
        let naturals = bar.debugSegmentNaturalWidths
        #expect(frames.count == 2)
        for (frame, natural) in zip(frames, naturals) {
            #expect(abs(frame.width - natural) < 0.5, "a stretched segment: \(frame.width) for \(natural)")
        }
        let start = frames[0].minX, end = width - frames[1].maxX
        #expect(start > 10 && abs(start - end) < 0.5, "end margins \(start) and \(end)")
    }

    /// The overflow net is unchanged (#2577): a sweep still narrows the
    /// strip, and the platter follows the narrower ceiling.
    @Test func aSweepStillNarrowsAPlatterThatFillsTheRoom() {
        let bar = PagedTabBar(titles: ["Chats", "Requests"], style: .navigationTitle)
        let selector = BarSelectorItem(strip: bar, id: "test.selector")
        let budget = BarSelectorBudget(barWidth: 402, leadingWidths: [44], trailingWidths: [44])
        selector.fit(budget)
        let before = bar.intrinsicContentSize.width
        #expect(selector.narrowAfterOverflow(budget))
        #expect(abs(bar.intrinsicContentSize.width - (before - BarSelectorItem.trimStep)) < 0.5)
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
