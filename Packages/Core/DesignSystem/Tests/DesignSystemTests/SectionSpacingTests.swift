import Testing
import UIKit
@testable import DesignSystem

/// The app's ONE section spacing (`Spacing.section`, `Spacing.sectionTitle`,
/// 2026-09-30): every title's LINE stands the same distance under the section
/// above it and over its own content, whichever way a surface hosts it — a
/// 44pt bar (`SectionTitleView`: For You's rows, the sound sheet, the drawer,
/// the wallet) or the pinned capsule's header (`SectionHeaderPillButton`:
/// For You's pushed lists, the inbox, search).
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

    /// The title bar: `Spacing.section` from a section's foot to the next
    /// title's line, `Spacing.sectionTitle` from that line to its content —
    /// at the default size and at a large one.
    @Test func theTitleBarKeepsTheSectionSpacing() {
        #expect(SectionTitleView.barHeight() == SectionTitleView.Metrics.height)
        let air = (SectionTitleView.Metrics.height - line) / 2
        #expect(abs(SectionTitleView.gapAbove() + air - Spacing.section) <= 0.5)
        #expect(abs(SectionTitleView.gapBelow() + air - Spacing.sectionTitle) <= 0.5)

        let large = UITraitCollection(preferredContentSizeCategory: .accessibilityLarge)
        let bigLine = SectionTitleView.titleFont(.standard, traits: large).lineHeight
        let bigAir = (SectionTitleView.barHeight(traits: large) - bigLine) / 2
        #expect(SectionTitleView.barHeight(traits: large) > SectionTitleView.Metrics.height, "the bar grows with the text")
        #expect(abs(SectionTitleView.gapAbove(traits: large) + bigAir - Spacing.section) <= 0.5)
    }

    /// The pushed lists' header: its title's line stands where
    /// `inlineTitleTop` says, and `Spacing.sectionTitle` over the first row
    /// — the pill itself not moving.
    @Test func thePillStandsItsLineOverTheRows() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        let pill = SectionHeaderPillButton()
        pill.setPillTitle("Recent")
        pill.pinAsHeader(in: host)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        let height = host.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height)
        ).height
        let lineTop = SectionHeaderPillButton.inlineTitleTop(traits: pill.traitCollection)
        let inline = UIFont.preferredFont(forTextStyle: .title3, compatibleWith: pill.traitCollection).lineHeight
        #expect(abs(height - (lineTop + inline) - Spacing.sectionTitle) <= 0.6,
                "the title's line is \(height - lineTop - inline) over the first row")
        #expect(pill.frame.minY == SectionHeaderPillButton.Metrics.float, "the pill moved")
    }
}
