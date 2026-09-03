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
