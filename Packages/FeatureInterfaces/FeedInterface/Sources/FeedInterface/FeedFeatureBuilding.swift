import CoreModels
import UIKit

/// Entry point contract for the Feed feature. Other modules (the app shell,
/// or features that embed feed surfaces) depend on this interface package —
/// never on the Feed implementation — so editing Feed internals recompiles
/// nothing but Feed itself.
@MainActor
public protocol FeedFeatureBuilding {
    func makeFeedViewController() -> UIViewController
    /// The detail screen for a single post — the destination the router pushes
    /// for a `.post` route (e.g. from the feed or a notification).
    func makePostDetailViewController(for postID: PostID) -> UIViewController
}
