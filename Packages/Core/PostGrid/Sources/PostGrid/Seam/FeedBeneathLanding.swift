import CoreModels
import UIKit

/// A page a reader is pushed over and closes DOWN onto: the place page,
/// inserted under the cluster feed (#2381). The feed stages that close
/// before the page is on the stack, so it asks the page two things through
/// this seam, the concrete page living in a feature the feed cannot import.
@MainActor
public protocol FeedBeneathLanding: AnyObject {
    /// The chrome the page will run under once it is uncovered, said before
    /// it is in a window (`HeroPageViewController.stagingChromeTop`).
    var stagingChromeTop: CGFloat? { get set }
    /// The card the close lands on, sized to `bounds`: the settled post's
    /// card when the page has one, nil for the plain slide. `settled` is the
    /// post the viewer is on, read at staging.
    func markerFlightLandingOrigin(sizedTo bounds: CGRect, settled: PostID?) -> TextRevealOrigin?
}
