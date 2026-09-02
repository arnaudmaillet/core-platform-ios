import Testing
import UIKit
@testable import CoreNavigation

/// WHO OWNS THE DOCK WHILE A SCREEN IS UP.
///
/// The shell reconciles the app's one tab bar from three places
/// (`MainTabCoordinator.syncTabBarVisibility`, `FeedFlowCoordinator.restoreTabBar`
/// and `FeedFeatureBuilder.restoreTabBar`), and all three used to read
/// `topViewController is any ZoomTransitionDestination` as "this screen covers
/// the bar, so the dock is its business". That was a proxy, and it held only
/// while every conformer happened to be a full-bleed snap surface.
///
/// The place page ended that: it conforms so its OWN dismissal can fly home to
/// the map marker, and it shows the dock like any other pushed screen. Read
/// through the proxy, the shell hid the bar under it and then skipped every
/// restore — the map came back with no dock at all and no gesture that brought
/// one back. Same family as `NativePopPolicyTests`, where conformance was
/// likewise mistaken for an answer about the dismissal.
///
/// These pin the three answers the shell depends on, in the exact polarity the
/// call sites spell out. That an override survives the existential is
/// `ZoomExistentialDispatchTests`' business, not this file's.
@MainActor
struct AppTabBarConcealmentTests {
    /// A screen with no zoom conformance at all — a settings list, a pushed
    /// relationship list — is never read as covering the bar. `nil`, not
    /// `false`: the shell asks a question the screen has never heard of, and
    /// both restore sites treat "no answer" and "no" identically.
    @Test func aScreenThatDoesNotFlyIsNotReadAsCoveringTheBar() {
        let top: UIViewController = UIViewController()
        #expect((top as? any ZoomTransitionDestination)?.concealsAppTabBar == nil)
        #expect((top as? any ZoomTransitionDestination)?.concealsAppTabBar != true,
                "the restore sites must run over a screen that never claimed the dock")
    }

    /// The default, unchanged for every conformer that shipped before the
    /// member existed: a snap surface covers the bar for its whole visit, so
    /// the shell keeps its hands off and the restores keep standing down.
    @Test func aFullBleedSurfaceStillConcealsWithoutSayingSo() {
        let feed: UIViewController = FullBleedDestination()
        #expect((feed as? any ZoomTransitionDestination)?.concealsAppTabBar == true)
    }

    /// The regression itself: a screen may fly home and still be an ordinary
    /// navigation citizen with a dock under it. Conformance answers the
    /// transition's question; it must not answer this one.
    @Test func aScreenThatFliesHomeMayStillShowTheDock() {
        let page: UIViewController = DockedDestination()
        #expect((page as? any ZoomTransitionDestination)?.concealsAppTabBar == false)
        #expect((page as? any ZoomTransitionDestination)?.concealsAppTabBar != true,
                "the place page's own pop must bring the bar back with it")
    }
}

// MARK: - Fixtures

/// The shape every conformer had before the member existed: says nothing, and
/// must keep hiding the bar for its whole visit.
private final class FullBleedDestination: UIViewController, ZoomTransitionDestination {
    func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect { .zero }
    func zoomFlightChrome() -> UIView? { nil }
    func setZoomContentHidden(_ hidden: Bool) {}
    func zoomTransitionDidEnd() {}
    var isReadyForInteractiveDismissal: Bool { true }
    func setContentScrollEnabled(_ enabled: Bool) {}
}

/// The place page's shape: conforms for its dismissal, keeps its dock.
private final class DockedDestination: UIViewController, ZoomTransitionDestination {
    func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect { .zero }
    func zoomFlightChrome() -> UIView? { nil }
    func setZoomContentHidden(_ hidden: Bool) {}
    func zoomTransitionDidEnd() {}
    var isReadyForInteractiveDismissal: Bool { true }
    func setContentScrollEnabled(_ enabled: Bool) {}

    var concealsAppTabBar: Bool { false }
}
