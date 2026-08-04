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
    /// Lays the pill into a host the way a header view does, and reports where
    /// its top edge lands.
    private func topOffset(leadsList: Bool) -> CGFloat {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        let pill = SectionHeaderPillButton()
        pill.setPillTitle("Recent")
        pill.pinAsHeader(in: host)
        pill.setLeadsList(leadsList)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        return pill.frame.minY
    }

    /// A header that OPENS a list sits flush: it is directly under the
    /// navigation bar's tab capsule, with nothing above it to be separated from.
    @Test func theFirstHeaderIsFlush() {
        #expect(topOffset(leadsList: true) == SectionHeaderPillButton.Metrics.float)
    }

    /// A header that FOLLOWS a section carries the gap, or its pill crowds the
    /// last row above it and reads as part of that section.
    @Test func aLaterHeaderCarriesTheSectionGap() {
        #expect(
            topOffset(leadsList: false)
                == SectionHeaderPillButton.Metrics.float + SectionHeaderPillButton.Metrics.sectionGap
        )
    }

    @Test func theGapIsTheDifferenceBetweenTheTwo() {
        #expect(
            topOffset(leadsList: false) - topOffset(leadsList: true)
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
        let followed = pill.frame.minY

        pill.setLeadsList(true)
        host.layoutIfNeeded()
        #expect(pill.frame.minY < followed)
        #expect(pill.frame.minY == SectionHeaderPillButton.Metrics.float)
    }

    /// The gap is in the range the design calls for — a margin, not a band.
    @Test func theGapIsAMarginNotABand() {
        #expect((12...16).contains(SectionHeaderPillButton.Metrics.sectionGap))
    }
}
