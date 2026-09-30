import Testing
import UIKit
@testable import DesignSystem

/// The app's ONE section spacing (`Spacing.section`, `Spacing.sectionTitle`,
/// 2026-09-30): every title's LINE stands the same distance under the section
/// above it and over its own content, whichever way a surface hosts it — a
/// 44pt bar (`SectionLinkHeaderView`, the sound sheet's titles) or the pinned
/// capsule's header (`SectionHeaderPillButton`, For You's pushed lists).
@MainActor
struct SectionSpacingTests {
    /// The title3 line at the default text size, bold as every title wears it.
    private let line = UIFont.systemFont(ofSize: 20, weight: .bold).lineHeight

    /// Apple-shaped numbers: a wide gap before a title, a tight one after it
    /// — the title reads as the head of what follows.
    @Test func theGapBeforeATitleIsAboutThreeTimesTheGapAfterIt() {
        #expect(Spacing.section == 28)
        #expect(Spacing.sectionTitle == 10)
        #expect((2.5...3.5).contains(Spacing.section / Spacing.sectionTitle))
    }

    /// A bar that centres its line counts its own air toward the gap above
    /// it: a 44pt bar holds ~10pt over a title3 line, so it asks 18 more.
    @Test func aBarCountsItsOwnAirTowardTheGap() {
        #expect(Spacing.sectionTitleBarHeight(lineHeight: line) == 44)
        #expect(Spacing.sectionGap(aboveTitleBar: 44, lineHeight: line) == 18)
        // Never a negative gap, however tall the bar.
        #expect(Spacing.sectionGap(aboveTitleBar: 200, lineHeight: line) == 0)
        // A larger text size grows the bar, never under 44.
        #expect(Spacing.sectionTitleBarHeight(lineHeight: 12) == 44)
        #expect(Spacing.sectionTitleBarHeight(lineHeight: 40) == 60)
    }

    /// For You's rows: `Spacing.section` from a row's foot to the next
    /// title's line, `Spacing.sectionTitle` from that line to its row.
    @Test func theLinkHeaderKeepsTheSectionSpacing() {
        let air = (SectionLinkHeaderView.height - line) / 2
        #expect(abs(SectionLinkHeaderView.gapAbove + air - Spacing.section) <= 0.5)
        #expect(abs(SectionLinkHeaderView.gapBelow + air - Spacing.sectionTitle) <= 0.5)
    }

    /// The pushed lists' header: its title's line stands where
    /// `inlineTitleTop` says, and a host asking `titleToContent` gets that
    /// line exactly that far over the first row — the pill itself not moving.
    @Test func thePillStandsItsLineOverTheRowsAsAsked() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        let pill = SectionHeaderPillButton()
        pill.setPillTitle("Recent")
        pill.pinAsHeader(in: host)
        func fittedHeight() -> CGFloat {
            host.setNeedsLayout()
            host.layoutIfNeeded()
            return host.systemLayoutSizeFitting(
                CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height)
            ).height
        }
        let untouched = fittedHeight()

        pill.setTitleToContent(Spacing.sectionTitle)
        let height = fittedHeight()
        let lineTop = SectionHeaderPillButton.inlineTitleTop(traits: pill.traitCollection)
        let inline = UIFont.preferredFont(forTextStyle: .title3, compatibleWith: pill.traitCollection).lineHeight
        #expect(abs(height - (lineTop + inline) - Spacing.sectionTitle) <= 0.6,
                "the title's line is \(height - lineTop - inline) over the first row")
        #expect(pill.frame.minY == SectionHeaderPillButton.Metrics.float, "the pill moved")

        // Recycled into a host that asks nothing: the float again.
        pill.setTitleToContent(nil)
        #expect(fittedHeight() == untouched)
    }
}
