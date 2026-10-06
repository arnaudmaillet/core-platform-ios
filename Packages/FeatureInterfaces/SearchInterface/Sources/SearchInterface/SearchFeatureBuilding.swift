import UIKit

/// Entry point contract for the Search feature. The app shell depends on this
/// interface package — never on the Search implementation — so editing Search
/// internals recompiles nothing but Search itself.
@MainActor
public protocol SearchFeatureBuilding {
    /// The search surface for the Search tab. Tapping a result routes to that
    /// entity (e.g. a profile) via the injected `Router`.
    func makeSearchViewController() -> UIViewController

    /// One `#tag`'s posts — Top and Recent (#524). `tag` without its `#`.
    func makeHashtagViewController(tag: String) -> UIViewController
}
