import CoreNavigation
import UIKit

/// Whether a screen may open a post now (#2379, stage A2): its stack is at
/// rest and it is (inside) the screen on top. A rule of UIKit's navigation
/// state, not of the feed's builder, so the post surfaces can ask it from
/// anywhere. `FeedFeatureBuilder.canOpen` answers through it.
@MainActor
enum PostOpening {
    static func canOpen(from presenter: UIViewController, on nav: UINavigationController) -> Bool {
        // A push or pop of this stack — not the stack's own modal presentation
        // (`isTransitioningItsStack`): the sound sheet's host opens its post
        // from that presentation's completion.
        guard !nav.isTransitioningItsStack, let top = nav.topViewController else { return false }
        var screen: UIViewController? = presenter
        while let current = screen, current !== top { screen = current.parent }
        return screen === top
    }
}
