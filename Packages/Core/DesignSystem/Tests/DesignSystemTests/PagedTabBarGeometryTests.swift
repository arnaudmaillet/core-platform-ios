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

    /// Long-press menus hang off the SEGMENT, so they must survive the segment
    /// being re-measured — and a segment with no menu must not answer a press.
    @Test func onlyASegmentGivenAMenuOffersOne() {
        let bar = laidOutBar(titles: ["All", "Requests", "Suggestions"])
        bar.setMenu(UIMenu(children: [UIAction(title: "Clear All Requests") { _ in }]), at: 1)

        #expect(bar.debugMenu(at: 0)?.titles == [])
        #expect(bar.debugMenu(at: 1)?.titles == ["Clear All Requests"])
        // The interaction is installed on every segment regardless: it is what
        // decides, per press, whether there is anything to show.
        #expect(bar.debugMenu(at: 0)?.hasInteraction == true)
        #expect(bar.debugMenu(at: 2)?.hasInteraction == true)
    }

    /// A badge clears the lens's trailing edge by MORE than the title clears
    /// its leading one, and the pair sits tighter together than either.
    ///
    /// The pill ends exactly where it is drawn where a letter carries its own
    /// side bearing, so matched insets read as crowding; and a count belongs to
    /// the word beside it, so the gap between them is the smallest number of
    /// the three.
    @Test func theBadgeClearsTheLensByMoreThanTheTitleDoes() {
        let style = PagedTabBar.Style.navigationTitle

        #expect(style.trailingInset > style.leadingInset)
        #expect(style.badgeSpacing < style.leadingInset)
        #expect(style.segmentPadding == style.leadingInset + style.trailingInset)
    }

    /// Unequal insets only come out right if the contents are shifted off the
    /// segment's centre by half their difference; centred, each end would get
    /// the mean of the two instead.
    @Test func unequalInsetsShiftTheContentsOffCentre() {
        let style = PagedTabBar.Style.navigationTitle

        #expect(style.contentOffset == (style.leadingInset - style.trailingInset) / 2)
        // Toward the leading edge, and by little enough that the titles still
        // read as centred.
        #expect(style.contentOffset < 0)
        #expect(abs(style.contentOffset) <= 1)
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
