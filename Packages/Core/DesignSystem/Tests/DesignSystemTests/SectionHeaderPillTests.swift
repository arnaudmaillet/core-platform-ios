import Testing
import UIKit
@testable import DesignSystem

/// Where the pill stands in the header that hosts it — the same for every
/// header of every list (the inbox's two tables, the inbox search's and the
/// search screen's collection views, For You's pushed lists).
@MainActor
struct SectionHeaderPillTests {
    /// Lays the pill into a host the way a header view does, and reports both
    /// the pill's own offset and the height the header ends up with.
    private func layout(title: String = "Recent") -> (pill: SectionHeaderPillButton, headerHeight: CGFloat) {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        let pill = SectionHeaderPillButton()
        pill.setPillTitle(title)
        pill.pinAsHeader(in: host)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        let fitted = host.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height)
        )
        return (pill, fitted.height)
    }

    /// ⚠️ **EVERY header's pill sits at the same offset.** A plain table PINS
    /// its section headers, and a pinned header carries its top margin with it
    /// — so a gap spent above the pill hung the second section's capsule lower
    /// than the first's for exactly as long as both were stuck to the top
    /// (measured on the inbox: `pillTop=8` for section 0, `24` for section 1).
    /// The section gap is the host's, at the foot of the section above.
    @Test func everyHeaderPinsItsPillAtTheSameOffset() {
        #expect(layout(title: "New").pill.frame.minY == SectionHeaderPillButton.Metrics.float)
        #expect(layout(title: "Recent").pill.frame.minY == SectionHeaderPillButton.Metrics.float)
        #expect(layout(title: "New").headerHeight == layout(title: "Recent").headerHeight)
    }

    /// The pill stands on the surface's title line — `SectionTitleView`'s one
    /// inset — whatever the host's own geometry: edge to edge in a table, 16pt
    /// in inside a compositional section's content insets.
    @Test func thePillStandsOnTheSurfacesTitleLine() {
        let surface = UIScrollView(frame: CGRect(x: 0, y: 0, width: 393, height: 600))
        for hostX: CGFloat in [0, 16] {
            let host = UIView(frame: CGRect(x: hostX, y: 100, width: 393 - 2 * hostX, height: 60))
            surface.addSubview(host)
            let pill = SectionHeaderPillButton()
            pill.setPillTitle("Recent")
            pill.pinAsHeader(in: host)
            pill.alignToSurface()
            host.layoutIfNeeded()
            let x = pill.convert(pill.bounds, to: surface).minX
            #expect(abs(x - SectionTitleView.Metrics.surfaceInset) < 0.5, "host at \(hostX): pill at \(x)")
        }
    }

    /// The gap a host leaves before the NEXT header puts that header's title
    /// line `Spacing.section` under the rows above — the app's one gap.
    @Test func theSectionGapCountsTheHeadersOwnRoom() {
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        let gap = SectionHeaderPillButton.sectionGap(traits: traits)
        let lineTop = SectionHeaderPillButton.inlineTitleTop(traits: traits)
        #expect(abs(gap + lineTop - Spacing.section) <= 0.5)
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

/// The count a header can carry after its title — `New 8` on For You's
/// pushed lists — as the app's one section title draws it: secondary text,
/// no badge (2026-09-30).
@MainActor
struct SectionHeaderCountTests {
    /// The width the pill asks for, in one shape, at one count.
    private func width(count: Int, presentation: SectionHeaderPillButton.Presentation) -> CGFloat {
        let pill = SectionHeaderPillButton()
        pill.setPillTitle("New")
        pill.setCount(count)
        pill.setPresentation(presentation, animated: false)
        // What the pill's hugging constraints size it to in a host — a bare
        // button's `systemLayoutSizeFitting` answers from its configuration.
        return pill.intrinsicContentSize.width
    }

    /// The count's room is the button's own size, in both shapes — so the
    /// glass capsule wraps "New" and its count together, and the inline
    /// title never runs under it.
    @Test func aCountWidensThePillInBothShapes() {
        for shape in [SectionHeaderPillButton.Presentation.inline, .pinned] {
            let bare = width(count: 0, presentation: shape)
            let counted = width(count: 23, presentation: shape)
            #expect(counted >= bare + SectionTitleView.Metrics.titleToCount + 8, "\(shape)")
        }
    }

    /// No count is the header it always was — the Messages inbox never sets
    /// one, and must not change by a point.
    @Test func noCountLeavesTheHeaderAsItWas() {
        let untouched = SectionHeaderPillButton()
        untouched.setPillTitle("New")
        let zeroed = SectionHeaderPillButton()
        zeroed.setPillTitle("New")
        zeroed.setCount(5)
        zeroed.setCount(0)
        #expect(untouched.intrinsicContentSize == zeroed.intrinsicContentSize)
        #expect(zeroed.accessibilityValue == nil)
    }

    /// VoiceOver hears the count with the header, not as a stray number:
    /// "New, 23 new, button".
    @Test func theCountIsSpokenWithTheHeader() {
        let pill = SectionHeaderPillButton()
        pill.setPillTitle("New")
        pill.setCount(23)
        #expect(pill.count == 23)
        #expect(pill.accessibilityLabel == "New")
        #expect(pill.accessibilityValue == "23 new")
    }

    /// The pill draws the app's ONE section title in both shapes: the count
    /// is plain secondary text, the title `.label` — only the size changes
    /// when it pins.
    @Test func bothShapesDrawTheSameTitle() {
        let pill = SectionHeaderPillButton()
        pill.setPillTitle("New")
        pill.setCount(3)
        let title = pill.debugTitleView
        #expect(title.debugTitleText == "New")
        #expect(title.debugCountText == "3")
        #expect(title.debugColors.title == .label)
        #expect(title.debugColors.count == .secondaryLabel)
        #expect(!title.debugShowsChevron, "a pill scrolls to its section; it pushes nothing")
        #expect(title.style == .standard)
        pill.setPresentation(.pinned, animated: false)
        #expect(title.style == .compact)
        #expect(title.debugCountText == "3")
    }
}
