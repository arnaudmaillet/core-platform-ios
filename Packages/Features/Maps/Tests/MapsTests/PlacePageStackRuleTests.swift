import Testing
import UIKit
@testable import Maps

/// **A STACK IS NOT ONLY WHAT IS DRAWN — IT IS WHAT BACK MEANS.**
///
/// A hierarchy marker's feed carries a place page for its VERTICAL dismissal to
/// land on. That page used to join the stack in the same transaction as the
/// feed, on the reasoning that it is never seen. True, and beside the point: the
/// chevron's single pop landed on a place page the viewer had never asked for.
/// Filmed twice, from a country marker and from a city one — and with it went
/// the map, because the place page takes the navigation delegate in
/// `viewDidAppear` and the map's own close-out is delivered through `didShow`,
/// so `activeTransition` was never cleared and no marker could be tapped again.
///
/// The reveal route had already reached the opposite conclusion and states it in
/// its own words: the page is inserted for a committed vertical dismissal and
/// taken out again if that dismissal is abandoned, "so the back button and the
/// horizontal close keep their map landing". These pin the same rule for the
/// hero route, on the pure arithmetic, because the alternative is a live
/// `MKMapView` and a gesture the simulator cannot inject.
@MainActor
struct PlacePageStackRuleTests {
    private func controllers(_ count: Int) -> [UIViewController] {
        (0..<count).map { _ in UIViewController() }
    }

    /// The commit: the page goes UNDER the feed, so the pop that follows lands
    /// on it rather than on the map.
    @Test func aCommittedVerticalGrabPutsThePageUnderTheFeed() throws {
        let stack = controllers(2)          // [map, feed]
        let place = UIViewController()

        let plan = try #require(
            MapsViewController.stack(stack, inserting: place, beneath: stack[1])
        )

        #expect(plan.count == 3)
        #expect(plan[0] === stack[0])
        #expect(plan[1] === place)
        #expect(plan[2] === stack[1])
    }

    /// ⚠️ AND IT IS NOT THERE AT REST, which is the whole defect. Nothing to
    /// insert under, nothing to do — the map is what one pop finds.
    @Test func thereIsNothingToInsertWhenTheFeedIsGone() {
        let map = UIViewController()
        let feed = UIViewController()
        #expect(MapsViewController.stack([map], inserting: UIViewController(), beneath: feed) == nil)
    }

    /// Idempotent: a grab that arms twice must not stack two copies.
    @Test func insertingAPageThatIsAlreadyThereDoesNothing() {
        let map = UIViewController()
        let place = UIViewController()
        let feed = UIViewController()
        #expect(MapsViewController.stack([map, place, feed], inserting: place, beneath: feed) == nil)
    }

    /// The undo, for an abandoned grab: the page leaves again so the chevron
    /// and the horizontal close keep their map landing.
    @Test func anAbandonedGrabTakesThePageBackOut() throws {
        let map = UIViewController()
        let place = UIViewController()
        let feed = UIViewController()

        let plan = try #require(MapsViewController.stack([map, place, feed], removing: place))

        #expect(plan.count == 2)
        #expect(plan[0] === map)
        #expect(plan[1] === feed)
    }

    /// Also idempotent: the removal runs from two places (the cancel hop and the
    /// card close's own pop bookkeeping), and the second must be a no-op rather
    /// than a mutation.
    @Test func removingAPageThatIsNotThereDoesNothing() {
        let map = UIViewController()
        let feed = UIViewController()
        #expect(MapsViewController.stack([map, feed], removing: UIViewController()) == nil)
    }

    /// The round trip is the identity — arm, abandon, and the stack the chevron
    /// sees is the one it started with.
    @Test func armingAndAbandoningLeavesTheStackExactlyAsItWas() throws {
        let stack = controllers(2)
        let place = UIViewController()

        let armed = try #require(
            MapsViewController.stack(stack, inserting: place, beneath: stack[1])
        )
        let undone = try #require(MapsViewController.stack(armed, removing: place))

        #expect(undone.count == stack.count)
        #expect(zip(undone, stack).allSatisfy { $0 === $1 })
    }
}

/// **THE POP'S DESTINATION DECIDES WHAT THE CLOSE FLIES TO.**
///
/// A marker's feed is a pager, and the presentation was chosen at the tap: a
/// media-faced marker opens with a hero, and a viewer who swipes onto a TEXT
/// post leaves that hero with nothing to fly. Filmed at 30fps: the page slid
/// horizontally off the screen — the platform's fallback, no window at all.
///
/// The cure is not to give the card close a wider licence but to aim it at the
/// screen the pop is actually going to. A vertical grab lands on the place page
/// and closes onto its tile; the chevron and a horizontal grab land on the MAP,
/// so they close onto the MARKER — whatever post the viewer paged to, and even
/// when there is no place page at all.
@MainActor
struct MapCardCloseTargetTests {
    /// The vertical grab, which is the only case that has ever had a card to
    /// land on.
    @Test func aVerticalGrabWithAPlacePageClosesOntoItsCard() {
        #expect(
            MapsViewController.closeTarget(axis: .vertical, hasLanding: true) == .placeCard
        )
    }

    /// ⚠️ THE FILMED CASE. The chevron and a horizontal grab both land on the
    /// map, so both close onto the marker.
    @Test func everyOtherAxisClosesOntoTheMarker() {
        #expect(MapsViewController.closeTarget(axis: .horizontal, hasLanding: true) == .marker)
    }

    /// ⚠️ AND WITH NO PLACE PAGE THERE IS NOTHING ELSE IT COULD BE. A single
    /// pin never had a close driver at all, so its chevron fell through to
    /// UIKit's native pop — visually the same slide, reached a different way.
    @Test func withoutAPlacePageBothAxesCloseOntoTheMarker() {
        #expect(MapsViewController.closeTarget(axis: .vertical, hasLanding: false) == .marker)
        #expect(MapsViewController.closeTarget(axis: .horizontal, hasLanding: false) == .marker)
    }
}

/// **`didAdd` IS NOT "SOMETHING NEW HAPPENED".**
///
/// MapKit calls it for every view it realizes — including the whole visible set
/// when the map comes back from a push — so popping in whatever it hands over
/// meant the entire map scale-and-faded in again on every return, with nothing
/// having changed. Filmed as markers re-landing after every post.
///
/// Only what this screen actually ADDED is an arrival. The rest are settled
/// explicitly rather than left alone: a recycled view can still be carrying a
/// cancelled pop's alpha, so "do nothing" would leave some markers invisible.
@MainActor
struct MapMarkerPopPartitionTests {
    private final class Marker {}

    private func partition(
        _ views: [Marker], pending: [Marker]
    ) -> (arriving: [Marker], settled: [Marker]) {
        MapsViewController.popPartition(
            views, pending: Set(pending.map(ObjectIdentifier.init))
        ) { ObjectIdentifier($0) }
    }

    /// The defect, stated: a batch nobody added animates nothing.
    @Test func aBatchWithNoArrivalsPopsNothing() {
        let views = [Marker(), Marker(), Marker()]
        let batch = partition(views, pending: [])

        #expect(batch.arriving.isEmpty)
        #expect(batch.settled.count == 3)
    }

    /// …and a genuine arrival still lands, which is what keeps the map feeling
    /// populated rather than stamped.
    @Test func onlyTheMarkersThisReconcileAddedArrive() {
        let old = [Marker(), Marker()]
        let fresh = Marker()
        let batch = partition(old + [fresh], pending: [fresh])

        #expect(batch.arriving.count == 1)
        #expect(batch.arriving.first === fresh)
        #expect(batch.settled.count == 2)
    }

    /// A view MapKit hands over with no annotation at all is settled, never
    /// popped — the alternative is animating something that has no identity.
    @Test func aViewWithNoIdentityIsSettled() {
        let orphan = Marker()
        let batch = MapsViewController.popPartition(
            [orphan], pending: [ObjectIdentifier(orphan)]
        ) { _ in nil }

        #expect(batch.arriving.isEmpty)
        #expect(batch.settled.count == 1)
    }

    /// Every view is accounted for exactly once — the two lists are a partition,
    /// not a filter and a guess.
    @Test func everyViewLandsInExactlyOneList() {
        let views = (0..<6).map { _ in Marker() }
        let batch = partition(views, pending: [views[1], views[4]])

        #expect(batch.arriving.count + batch.settled.count == views.count)
        let seen = Set((batch.arriving + batch.settled).map(ObjectIdentifier.init))
        #expect(seen.count == views.count)
    }
}
