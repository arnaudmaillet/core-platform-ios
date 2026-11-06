import Testing
import UIKit
@testable import Feed

/// A way into the comments field (a tap, Reply, a mention) expands a
/// collapsed sheet when it can, and the keys come to the detached bar: one
/// movement, never a rise with the keys then a drop without them (#2153, the
/// owner 2026-11-05).
@MainActor
struct CommentsSheetFieldRouteTests {
    private typealias Session = SnapCommentsSheetSession

    @Test func fromCollapsedWithMoreToShowTheFieldExpandsTheSheet() {
        let route = Session.fieldRoute(selected: Session.detent, offersExpanded: true)
        #expect(route.expands)
        #expect(route.detached, "the keys went to the sheet's own bar: UIKit would raise it first")
    }

    /// No detent selected yet reads as collapsed, the sheet's first height.
    @Test func noSelectedDetentReadsAsCollapsed() {
        let route = Session.fieldRoute(selected: nil, offersExpanded: true)
        #expect(route.expands && route.detached)
    }

    /// Few comments, no expanded detent: the sheet rides the keys, as before.
    @Test func withNothingToExpandToTheSheetRidesTheKeys() {
        let route = Session.fieldRoute(selected: Session.detent, offersExpanded: false)
        #expect(!route.expands)
        #expect(!route.detached)
    }

    /// Expanded already: the keys go to the detached bar and nothing moves.
    @Test func fromExpandedNothingMoves() {
        let route = Session.fieldRoute(selected: Session.expandedDetent, offersExpanded: true)
        #expect(!route.expands)
        #expect(route.detached)
    }
}
