import Testing
import UIKit
@testable import DesignSystem

/// The tab capsule's internal geometry, which is otherwise only checkable by
/// measuring pixels in a screenshot — and which drifts silently, because every
/// one of these failures still renders a plausible-looking bar.
@MainActor
struct PagedTabBarGeometryTests {
    /// Lays the bar out at its own intrinsic size, which is what a navigation
    /// bar's title slot gives it when nothing is competing for the room.
    private func laidOutBar(titles: [String], style: PagedTabBar.Style = .navigationTitle) -> PagedTabBar {
        let bar = PagedTabBar(titles: titles, style: style)
        bar.frame = CGRect(origin: .zero, size: bar.intrinsicContentSize)
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        return bar
    }

    @Test func theLensClearsTheCapsuleEquallyOnEverySide() {
        let bar = laidOutBar(titles: ["All", "Requests", "Suggestions"])
        guard let alignment = bar.debugLensAlignment else {
            Issue.record("the bar reported no lens")
            return
        }
        let lens = alignment.segment

        // Vertical: the capsule's height minus the lens's, halved.
        let vertical = (PagedTabBar.Style.navigationTitle.capsuleHeight - lens.height) / 2
        // Horizontal: the leading lens starts this far into the capsule.
        let horizontal = lens.minX

        #expect(vertical == horizontal)
    }

    /// ⚠️ **THE PILL STANDS 4pt INSIDE THE VISIBLE CAPSULE ON EVERY HOST, AND
    /// THE PILL IS WHAT CARRIES IT.** Standing alone or in an accessory's
    /// container the capsule is the view and the lens is inset inside its
    /// segment; in a bar item's platter the capsule reaches 4pt beyond the view
    /// on every side (measured: a 149×36 host in a 157×44 platter) and the lens
    /// stands on the view's own edge, so that the platter's ring is the
    /// clearance rather than stacking on top of one of ours — a lens inset 4pt
    /// inside the view there would land 8pt inside the pill the viewer sees.
    ///
    /// Read in the CAPSULE's space, where the two are the same number.
    @Test func theLensStandsTheSameClearanceInsideTheVisibleCapsuleOnEveryHost() {
        for hosting in [SelectorHosting.standalone, .container, .platter] {
            let bar = PagedTabBar(titles: ["All", "Requests", "Suggestions"], style: .navigationTitle)
            bar.hosting = hosting
            bar.frame = CGRect(origin: .zero, size: bar.intrinsicContentSize)
            bar.setNeedsLayout()
            bar.layoutIfNeeded()
            guard let lens = bar.debugLensAlignment?.segment else {
                Issue.record("\(hosting): the bar reported no lens")
                return
            }
            let capsuleHeight = bar.debugCapsuleShape.height
            #expect(lens.minX == 4, "\(hosting): leading clearance \(lens.minX)")
            #expect(lens.minY == 4, "\(hosting): top clearance \(lens.minY)")
            #expect(lens.height == capsuleHeight - 8, "\(hosting): lens \(lens.height) in \(capsuleHeight)")
        }
    }

    /// The capsule the viewer sees is the bar's own view everywhere but in a
    /// platter, where it reaches the platter's 4pt beyond every edge.
    @Test func onlyAPlatterHostedCapsuleReachesBeyondTheBar() {
        let reaches: [(SelectorHosting, CGFloat)] = [(.standalone, 0), (.container, 0), (.platter, 4)]
        for (hosting, reach) in reaches {
            let bar = laidOutBar(titles: ["All", "Requests"])
            bar.hosting = hosting
            bar.layoutIfNeeded()
            let capsule = bar.debugCapsuleShape.height
            let expected = bar.bounds.height + reach * 2
            #expect(abs(capsule - expected) < 0.5,
                    "\(hosting): capsule \(capsule) for a \(bar.bounds.height) bar, expected \(expected)")
        }
    }

    /// The VISIBLE capsule is the same width on every host — the segments are
    /// measured the same way everywhere, with the pill's clearance inside them.
    /// What differs is how much of it is the bar's own view: inside a platter
    /// the ring is the platter's, so the view asks for 8pt less and the platter
    /// puts the 8pt back.
    @Test func theVisibleCapsuleIsTheSameWidthOnEveryHost() {
        let titles = ["All", "Requests", "Suggestions"]
        let standalone = PagedTabBar(titles: titles, style: .navigationTitle)
        let container = PagedTabBar(titles: titles, style: .navigationTitle)
        container.hosting = .container
        let platter = PagedTabBar(titles: titles, style: .navigationTitle)
        platter.hosting = .platter
        #expect(standalone.intrinsicContentSize.width == container.intrinsicContentSize.width)
        #expect(standalone.intrinsicContentSize.width == platter.intrinsicContentSize.width + 8)
    }

    /// ⚠️ **THE STRIP KEEPS NO MARGIN OF ITS OWN.** The first segment starts at
    /// the capsule's very edge and the last ends at it, so a crowded strip
    /// scrolls its titles right up to the glass; the 4pt the viewer sees is the
    /// pill's, inside the segment. A padding on the row here is the defect this
    /// bar shipped for a year — invisible at rest, and a clipped title under a
    /// scroll.
    @Test func theSegmentsRunFromEdgeToEdgeOfTheCapsule() {
        let bar = laidOutBar(titles: ["All", "Requests", "Suggestions"])
        let frames = bar.debugSegmentFrames
        #expect(frames.first?.minX == 0, "first segment starts at \(frames.first?.minX ?? -1)")
        #expect(frames.last?.maxX == bar.bounds.width, "last segment ends at \(frames.last?.maxX ?? -1) of \(bar.bounds.width)")
    }

    /// A segment narrower than the lens is tall cannot draw a round selection:
    /// the pill's radius is half its height, which would exceed half its width.
    @Test func aShortTitleStillSelectsAsACircle() {
        let bar = laidOutBar(titles: ["1", "2"])
        guard let alignment = bar.debugLensAlignment else {
            Issue.record("the bar reported no lens")
            return
        }
        #expect(alignment.segment.width >= alignment.segment.height)
    }

    /// The lens is derived from segment frames one layout pass behind unless the
    /// row announces itself — the defect this bar has already shipped once.
    @Test func theLensFramesTheSegmentItIsSupposedTo() {
        let bar = laidOutBar(titles: ["All", "Requests", "Suggestions"])
        bar.setBadge(11, at: 0)
        guard let alignment = bar.debugLensAlignment else {
            Issue.record("the bar reported no lens")
            return
        }
        #expect(abs(alignment.lens.width - alignment.segment.width) < 0.5)
        #expect(abs(alignment.lens.minX - alignment.segment.minX) < 0.5)
    }

    /// A title view may not scroll — it has nowhere to scroll to that would not
    /// hide a tab — so at its own intrinsic width nothing may overflow.
    @Test func theTitleSlotBarNeverOverflowsAtItsIntrinsicWidth() {
        let bar = laidOutBar(titles: ["All", "Requests", "Suggestions"])
        bar.setBadge(11, at: 0)
        bar.setBadge(2, at: 1)
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        bar.frame = CGRect(origin: .zero, size: bar.intrinsicContentSize)
        bar.layoutIfNeeded()

        #expect(bar.debugOverflow == 0)
    }

    /// A segment's two ends clear the lens by the SAME amount, so its contents
    /// sit dead centre — and the title and its count sit closer to each other
    /// than either sits to an end, so the pair reads as one object.
    @Test func aSegmentClearsTheLensEquallyAtBothEnds() {
        let style = PagedTabBar.Style.navigationTitle

        #expect(style.leadingInset == style.trailingInset)
        #expect(style.badgeSpacing < style.leadingInset)
        #expect(style.segmentPadding == style.leadingInset + style.trailingInset)
    }

    /// Equal insets mean no shift at all. The offset stays DERIVED rather than
    /// hard-coded to zero: a segment is as wide as its contents plus both
    /// insets, so centred contents hand each end the mean of the two, and only
    /// a shift of half their difference gives each the number it claims. Zero
    /// is that formula's answer today, not a separate rule.
    @Test func equalInsetsLeaveTheContentsCentred() {
        let style = PagedTabBar.Style.navigationTitle

        #expect(style.contentOffset == (style.leadingInset - style.trailingInset) / 2)
        #expect(style.contentOffset == 0)
    }

    /// The pill stays SMALL beside a 13pt title — no more than half the lens.
    ///
    /// This is the constraint that rules out four-sided symmetry: equal margins
    /// would force `badgeHeight = lensHeight - 2 × clearance`, which at any
    /// affordable clearance is a 28pt coin. Compactness won; the pill's
    /// vertical clearance is therefore larger than either horizontal inset, on
    /// purpose.
    @Test func theCountPillStaysCompact() {
        let style = PagedTabBar.Style.navigationTitle

        #expect(style.badgeHeight <= style.lensHeight / 2)
        #expect((style.lensHeight - style.badgeHeight) / 2 > style.trailingInset)
    }

    /// A pill can never be narrower than it is tall: its corner radius is half
    /// its height, and below that width the capsule degenerates — the same rule
    /// the lens's own disk floor states.
    @Test func theCountPillIsNeverNarrowerThanItIsTall() {
        let bar = laidOutBar(titles: ["All", "Requests"])
        bar.setBadge(2, at: 0)
        bar.setNeedsLayout()
        bar.layoutIfNeeded()

        let style = PagedTabBar.Style.navigationTitle
        // A one-digit count measures far less than the pill's height, so this is
        // the case where the floor has to do the work.
        #expect(bar.debugBadgeSize(at: 0)?.width ?? 0 >= style.badgeHeight)
    }

    /// A badge widens its segment, and the count pill's own height is stated so
    /// its clearance inside the lens is equal above and below whatever the font
    /// does.
    @Test func aBadgeWidensItsSegmentWithoutChangingTheLensHeight() {
        let bar = laidOutBar(titles: ["All", "Requests"])
        let before = bar.debugLensAlignment?.segment ?? .zero
        bar.setBadge(11, at: 0)
        let after = bar.debugLensAlignment?.segment ?? .zero

        #expect(after.width > before.width)
        #expect(after.height == before.height)
    }
}
