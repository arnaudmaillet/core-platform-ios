import Testing
import UIKit
@testable import DesignSystem

/// The one rule every sectioned list in the app shares: the first header is
/// flush, later ones carry a margin.
///
/// Tested on the pill rather than on each host, because the pill is where the
/// rule lives — four hosts across two features (the inbox's two tables, the
/// compose picker's and the search screen's collection views, and For You's
/// Following list) all render it by asking this one object. A per-screen
/// screenshot proves one of them; this proves the thing they have in common.
@MainActor
struct SectionHeaderPillTests {
    /// Lays the pill into a host the way a header view does, and reports both
    /// the pill's own offset and the height the header ends up with.
    private func layout(leadsList: Bool) -> (pillTop: CGFloat, headerHeight: CGFloat) {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        let pill = SectionHeaderPillButton()
        pill.setPillTitle("Recent")
        pill.pinAsHeader(in: host)
        pill.setLeadsList(leadsList)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        let fitted = host.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height)
        )
        return (pill.frame.minY, fitted.height)
    }

    /// ⚠️ **EVERY header's pill sits at the same offset, first or not.**
    ///
    /// A plain table PINS its section headers, and a pinned header carries its
    /// top margin with it — so a gap spent above the pill hung the second
    /// section's capsule lower than the first's for exactly as long as both were
    /// stuck to the top of the list, which is the one place they are compared.
    /// Measured on the inbox before this changed: `pillTop=8` for section 0 and
    /// `pillTop=24` for section 1.
    @Test func everyHeaderPinsItsPillAtTheSameOffset() {
        #expect(layout(leadsList: true).pillTop == SectionHeaderPillButton.Metrics.float)
        #expect(layout(leadsList: false).pillTop == SectionHeaderPillButton.Metrics.float)
    }

    /// The separation is still THERE — it just sits below the pill, so a
    /// following section is still parted from the rows above it.
    @Test func aLaterHeaderStillCarriesTheSectionGap() {
        #expect(
            layout(leadsList: false).headerHeight - layout(leadsList: true).headerHeight
                == SectionHeaderPillButton.Metrics.sectionGap
        )
    }

    /// ⚠️ Header views are RECYCLED across sections, so the state has to be
    /// re-stated on every configure rather than set once. A pill that kept the
    /// gap from the "Recent" it last rendered would carry it into "New".
    @Test func theGapIsReversibleOnReuse() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        let pill = SectionHeaderPillButton()
        pill.pinAsHeader(in: host)

        pill.setLeadsList(false)
        host.layoutIfNeeded()
        let followedHeight = host.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height)
        ).height

        pill.setLeadsList(true)
        host.layoutIfNeeded()
        let leadingHeight = host.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height)
        ).height
        #expect(leadingHeight < followedHeight)
        // And the pill has not moved, either way.
        #expect(pill.frame.minY == SectionHeaderPillButton.Metrics.float)
    }

    /// The gap is in the range the design calls for — a margin, not a band.
    @Test func theGapIsAMarginNotABand() {
        #expect((12...16).contains(SectionHeaderPillButton.Metrics.sectionGap))
    }
}

/// The header wears two shapes, and which one is decided by where it sits.
@MainActor
struct SectionHeaderPresentationTests {
    /// A header inside a scroll view, `distance` points below the pin line.
    private func makeHeader(distance: CGFloat) -> (SectionHeaderPillButton, UIScrollView) {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 500))
        scrollView.contentSize = CGSize(width: 320, height: 2000)
        let host = UIView(frame: CGRect(x: 0, y: distance, width: 320, height: 60))
        scrollView.addSubview(host)
        let pill = SectionHeaderPillButton()
        pill.setPillTitle("Recent")
        pill.pinAsHeader(in: host)
        scrollView.layoutIfNeeded()
        return (pill, scrollView)
    }

    /// In the flow it is typography: a large bold title introducing the rows
    /// under it.
    @Test func aHeaderInTheFlowIsInline() {
        let (pill, scrollView) = makeHeader(distance: 300)
        pill.updatePresentation(in: scrollView)
        #expect(pill.presentation == .inline)
    }

    /// Pinned it is chrome: floating over content it no longer introduces.
    @Test func aHeaderHeldAtThePinLineIsACapsule() {
        let (pill, scrollView) = makeHeader(distance: 400)
        scrollView.contentOffset = CGPoint(x: 0, y: 400)
        pill.updatePresentation(in: scrollView)
        #expect(pill.presentation == .pinned)
    }

    /// ⚠️ Touching the pin line is not being HELD at it. The first header sits
    /// on that line at rest — it is the first thing in the list — and a distance
    /// test alone made it a capsule before the viewer had scrolled a point, so
    /// the inline shape was one you could never actually see.
    @Test func theFirstHeaderIsATitleUntilTheListMoves() {
        let (pill, scrollView) = makeHeader(distance: 0)
        pill.updatePresentation(in: scrollView)
        #expect(pill.presentation == .inline)

        scrollView.contentOffset = CGPoint(x: 0, y: 120)
        pill.updatePresentation(in: scrollView)
        #expect(pill.presentation == .pinned)
    }

    /// Pulling the list past its top is not scrolling into it: a bounce must not
    /// form capsules.
    @Test func aRubberBandBounceLeavesItInline() {
        let (pill, scrollView) = makeHeader(distance: 0)
        scrollView.contentOffset = CGPoint(x: 0, y: -80)
        pill.updatePresentation(in: scrollView)
        #expect(pill.presentation == .inline)
    }

    /// It forms just BEFORE it lands, not on contact — a morph that starts on
    /// collision reads as a reaction to it.
    @Test func itFormsShortOfThePinLine() {
        let gap = SectionHeaderPillButton.Metrics.morphDistance - 1
        let (pill, scrollView) = makeHeader(distance: 400)
        scrollView.contentOffset = CGPoint(x: 0, y: 400 - gap)
        pill.updatePresentation(in: scrollView)
        #expect(pill.presentation == .pinned)
    }

    /// The decision follows the scroll, both ways: a header that pins and then
    /// scrolls back down returns to being a title.
    @Test func theShapeFollowsTheScrollInBothDirections() {
        let (pill, scrollView) = makeHeader(distance: 300)
        pill.updatePresentation(in: scrollView)
        #expect(pill.presentation == .inline)

        // Scrolled until the header is against the top.
        scrollView.contentOffset = CGPoint(x: 0, y: 300)
        pill.updatePresentation(in: scrollView)
        #expect(pill.presentation == .pinned)

        scrollView.contentOffset = .zero
        pill.updatePresentation(in: scrollView)
        #expect(pill.presentation == .inline)
    }

    /// ⚠️ The two shapes have different type sizes, and the header's HEIGHT must
    /// not follow: a self-sizing header that re-measured mid-scroll would shove
    /// every row below it, and the morph would jitter the whole list.
    @Test func theHeightIsTheSameInBothShapes() {
        let (pill, scrollView) = makeHeader(distance: 300)
        pill.updatePresentation(in: scrollView)
        scrollView.layoutIfNeeded()
        let inlineHeight = pill.frame.height

        pill.setPresentation(.pinned, animated: false)
        scrollView.layoutIfNeeded()
        #expect(pill.frame.height == inlineHeight)
    }

    /// Tapping keeps working in both shapes — the pinned capsule is what the
    /// viewer actually reaches for, but a title in the flow is a control too.
    @Test func tappingWorksInBothShapes() {
        let (pill, _) = makeHeader(distance: 300)
        var taps = 0
        pill.onTap = { taps += 1 }

        pill.sendActions(for: .primaryActionTriggered)
        pill.setPresentation(.pinned, animated: false)
        pill.sendActions(for: .primaryActionTriggered)

        #expect(taps == 2)
    }

    /// Re-stating the shape it already has is a no-op, so a scroll tick that
    /// changes nothing cannot start a crossfade — thirty of those a second
    /// would leave the header permanently mid-dissolve.
    @Test func restatingTheSameShapeDoesNothing() {
        let (pill, scrollView) = makeHeader(distance: 0)
        pill.updatePresentation(in: scrollView)
        let first = pill.presentation
        pill.updatePresentation(in: scrollView)
        #expect(pill.presentation == first)
    }
}
