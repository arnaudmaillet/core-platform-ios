import UIKit

/// A screen a flight lands on: what navigation needs to know of the
/// transition engine's destinations (#2384). `ZoomTransitionDestination`, in
/// Transitions, refines it with everything the flight itself asks; the tab
/// bar's policy and the viewport share only need to tell such a screen apart
/// and read whether it covers the dock.
@MainActor
public protocol FlightDestination: AnyObject {
    /// Whether this destination COVERS the app's tab bar for its whole visit.
    ///
    /// ⚠️ THE SAME MISTAKE AS `ZoomTransitionDestination.zoomOwnsInteractiveDismissal`
    /// once was (conformance read as the answer), made a second time elsewhere.
    /// Three call sites in the shell — `MainTabCoordinator.syncTabBarVisibility`,
    /// `FeedFlowCoordinator.restoreTabBar` and `FeedFeatureBuilder.restoreTabBar`
    /// — read `topViewController is any ZoomTransitionDestination` as "the top
    /// screen is a full-bleed snap surface, so the dock belongs to it". That
    /// held only as long as every conformer happened to be one.
    ///
    /// The place page broke it: it conforms so its OWN dismissal can fly home
    /// to the map marker, while being an ordinary navigation citizen that shows
    /// the bar like any pushed screen. Conformance and dock-concealment came
    /// apart, and the shell believed the proxy — it hid the bar under the place
    /// page and then skipped every restore, so the map came back with no dock
    /// at all and no gesture that brought one back.
    ///
    /// Defaults to `true`: every other conformer today is a full-bleed snap
    /// surface and keeps behaving exactly as it does. A screen that flies but
    /// does not cover says `false`.
    var concealsAppTabBar: Bool { get }
}

public extension FlightDestination {
    var concealsAppTabBar: Bool { true }
}
