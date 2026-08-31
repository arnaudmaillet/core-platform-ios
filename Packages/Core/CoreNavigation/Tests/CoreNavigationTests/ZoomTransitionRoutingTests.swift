import Testing
import UIKit
@testable import CoreNavigation

/// `ZoomTransitionController`'s delegate answers — which transitions it
/// customises, which it leaves native, and what it retains while one runs.
///
/// All of it is synchronous delegate arithmetic (no animation is started by
/// asking), so the scoping that keeps a comments push native above the feed is
/// pinnable headless — the rule the class header states and nothing asserted.
@MainActor
struct ZoomTransitionRoutingTests {
    private func staged() -> (
        controller: ZoomTransitionController,
        nav: UINavigationController,
        feed: RoutedFeed,
        source: RoutedSource
    ) {
        let source = RoutedSource()
        let feed = RoutedFeed()
        let controller = ZoomTransitionController(source: source, destination: feed)
        let nav = UINavigationController(rootViewController: UIViewController())
        return (controller, nav, feed, source)
    }

    /// Only the registered pair is customised: the feed's own push and pop get
    /// animators, anything else on the stack stays native (nil) — the comments
    /// detail above the feed is the case the scoping exists for.
    @Test func onlyTheRegisteredPairGetsAnimators() {
        let (controller, nav, feed, _) = staged()
        let other = UIViewController()

        let push = controller.navigationController(
            nav, animationControllerFor: .push, from: other, to: feed
        )
        #expect(push != nil, "the feed's own push lost its flight")
        let pop = controller.navigationController(
            nav, animationControllerFor: .pop, from: feed, to: other
        )
        #expect(pop != nil, "the feed's own pop lost its flight")

        let foreignPush = controller.navigationController(
            nav, animationControllerFor: .push, from: feed, to: other
        )
        #expect(foreignPush == nil, "a detail pushed above the feed must stay native")
        let foreignPop = controller.navigationController(
            nav, animationControllerFor: .pop, from: other, to: feed
        )
        #expect(foreignPop == nil, "a pop that is not the feed's must stay native")
    }

    /// Presenting asks the destination to stand its playback down BEFORE the
    /// push (the only moment early enough), through the initialiser.
    @Test func constructionWarnsTheDestinationBeforeAnythingMoves() {
        let (_, _, feed, _) = staged()
        #expect(feed.willBeginCalls == 1)
    }

    /// A flight gets a dormant interruptor — created when UIKit asks for the
    /// interaction controller, retained for the flight, and released the
    /// moment `didShow` reports ANY completed transition. Observed through the
    /// census, because the retention is deliberately private.
    @Test func theDormantInterruptorLivesExactlyOneFlight() throws {
        let (controller, nav, feed, _) = staged()
        let baseline = ZoomDebugCensus.count(ZoomDebugCensus.Key.interruptor)

        let animator = try #require(controller.navigationController(
            nav, animationControllerFor: .push, from: UIViewController(), to: feed
        ))
        // Held in a var and dropped before `didShow`: the census counts LIVE
        // instances, and a test keeping its own strong reference would be the
        // leak it is asserting against.
        var interaction = controller.navigationController(
            nav, interactionControllerFor: animator
        )
        #expect(interaction != nil, "an interruptible flight got no catcher")
        #expect(ZoomDebugCensus.count(ZoomDebugCensus.Key.interruptor) == baseline + 1)
        interaction = nil
        #expect(ZoomDebugCensus.count(ZoomDebugCensus.Key.interruptor) == baseline + 1,
                "the controller alone must keep the catcher for the flight")

        controller.navigationController(nav, didShow: feed, animated: true)
        #expect(ZoomDebugCensus.count(ZoomDebugCensus.Key.interruptor) == baseline,
                "the interruptor outlived the flight it served")
    }

    /// `didShow` routes by WHAT showed: the feed reports the destination
    /// shown; a registered intermediate reports its own hook and neither of
    /// the others; anything else with the feed gone is the source's return.
    @Test func didShowRoutesToExactlyOneHook() {
        let (controller, nav, feed, _) = staged()
        let gallery = UIViewController()
        let elsewhere = UIViewController()
        controller.setDismissSource(RoutedSource(), for: gallery)

        var shown = 0
        var returned = 0
        var intermediates: [UIViewController] = []
        controller.onDestinationShown = { shown += 1 }
        controller.onSourceReturned = { returned += 1 }
        controller.onDismissedToIntermediate = { intermediates.append($0) }

        controller.navigationController(nav, didShow: feed, animated: true)
        #expect(shown == 1 && returned == 0 && intermediates.isEmpty)

        controller.navigationController(nav, didShow: gallery, animated: true)
        #expect(shown == 1 && returned == 0 && intermediates == [gallery],
                "a landing on the intermediate is not the origin's return")

        controller.navigationController(nav, didShow: elsewhere, animated: true)
        #expect(shown == 1 && returned == 1)
    }

    /// A detail pushed ABOVE the feed reports nothing at all: the feed is
    /// still on the stack, so the flight is not over and no hook may fire.
    @Test func aDetailAboveTheFeedReportsNothing() {
        let (controller, nav, feed, _) = staged()
        nav.pushViewController(feed, animated: false)
        let detail = UIViewController()
        nav.pushViewController(detail, animated: false)

        var returned = 0
        controller.onSourceReturned = { returned += 1 }
        controller.navigationController(nav, didShow: detail, animated: true)
        #expect(returned == 0, "a comments push above the feed ended the flight")
    }
}

// MARK: - Doubles

private final class RoutedSource: NSObject, ZoomTransitionSource {
    func zoomHeroFrame(in container: UICoordinateSpace) -> CGRect {
        CGRect(x: 10, y: 10, width: 80, height: 80)
    }
    var zoomSourceIsOnScreen: Bool { true }
    func makeZoomFlightCard() -> any ZoomFlightCard { RoutedCard() }
    func setZoomSourceHidden(_ hidden: Bool) {}
}

private final class RoutedCard: UIView, ZoomFlightCard {
    var zoomRestingCornerRadius: CGFloat { 10 }
    var zoomRestingChrome: UIView? { nil }
    func setZoomCornerRadius(_ radius: CGFloat) {}
}

private final class RoutedFeed: UIViewController, ZoomTransitionDestination {
    private(set) var willBeginCalls = 0
    func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect { .zero }
    func zoomFlightChrome() -> UIView? { nil }
    func setZoomContentHidden(_ hidden: Bool) {}
    func zoomTransitionDidEnd() {}
    var isReadyForInteractiveDismissal: Bool { true }
    func setContentScrollEnabled(_ enabled: Bool) {}
    func zoomTransitionWillBegin() { willBeginCalls += 1 }
}
