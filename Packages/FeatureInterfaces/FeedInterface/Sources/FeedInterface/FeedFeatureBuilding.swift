import CoreModels
import UIKit

/// How the post-detail screen presents.
public enum PostDetailMode: Sendable, Equatable {
    /// The full post (header, media, engagement) above its comments — used when
    /// arriving at a post you can't already see (e.g. from a notification).
    case full
    /// Comments + compose bar only, no post header/media — used from the snap
    /// feed, where the post is already full-screen. Text-only snap pages use
    /// this mode too: their engagement is pixel-identical to the media
    /// layouts' (the floating card simply has an empty media slot), so one
    /// mode serves every hosted engagement.
    case commentsOnly
}

/// How the For You tab should present ITSELF in the app's tab bar, given
/// whatever the viewer has the screen set to.
///
/// The tab item is not decoration here — For You is a lens over a corpus, and
/// which lens is active is a mode the viewer chose and can forget they chose.
/// A bar item that still says "For You" with a sparkle while the screen is
/// filtered to Work is the one place that state is invisible, and it is the
/// place someone looks to decide whether to come back.
///
/// Carried as plain data across the interface boundary — a title, an SF Symbol
/// name and a count — so the shell can build a `UITab` from it without
/// importing Feed or knowing that `ContentContext` exists.
public struct ForYouTabPresentation: Equatable, Sendable {
    /// The active lens's name — what the tab item should read.
    public let title: String
    /// The active lens's SF Symbol name, for the item's image.
    public let symbol: String
    /// How much is waiting under that lens. Zero means no badge.
    public let badgeCount: Int

    public init(title: String, symbol: String, badgeCount: Int) {
        self.title = title
        self.symbol = symbol
        self.badgeCount = badgeCount
    }
}

/// Entry point contract for the Feed feature. Other modules (the app shell,
/// or features that embed feed surfaces) depend on this interface package —
/// never on the Feed implementation — so editing Feed internals recompiles
/// nothing but Feed itself.
@MainActor
public protocol FeedFeatureBuilding {
    func makeFeedViewController() -> UIViewController
    /// The For You tab's root: a Discover mosaic and a Following timeline under
    /// one content lens, where tapping a tile opens the full-screen feed seeded
    /// from that page's ordered posts.
    ///
    /// It lives behind the *feed* builder rather than a feature of its own
    /// because the destination it opens (`makeSnapFeedViewController`) and the
    /// read path it shares are both here — one repository, one post cache, so
    /// a tapped tile is already warm in the feed it expands into.
    ///
    /// `onTabPresentationChange` reports how the shell's own bar item should
    /// read — see `ForYouTabPresentation`. It fires on the first load and on
    /// every lens change after it, including while the tab is off screen, which
    /// is the case the bar item exists for.
    func makeForYouViewController(
        onTabPresentationChange: ((ForYouTabPresentation) -> Void)?
    ) -> UIViewController
    /// The detail screen for a single post. `.full` for the `.post` route (e.g.
    /// from a notification); `.commentsOnly` for the `.comments` route (the snap
    /// feed's comment button).
    func makePostDetailViewController(for postID: PostID, mode: PostDetailMode) -> UIViewController
    /// A full-screen snap feed seeded with a fixed, ordered set of posts rather
    /// than the following timeline — the surface a Maps pin/cluster tap expands
    /// into. Reuses the entire snap feed (video pool, likes, comments, active-
    /// cell lifecycle); only the data source differs. The returned VC conforms
    /// to `ZoomTransitionDestination` so a hero transition can drive it.
    func makeSnapFeedViewController(postIDs: [PostID]) -> UIViewController
    /// Best-effort, cancellable warming of these posts into the shared cache, so
    /// a subsequent `makeSnapFeedViewController` hydrates from memory rather than
    /// the network — used by Maps to prefetch the visible pins on viewport
    /// settle, eliminating the metadata desync on tap. Safe for ids never opened.
    func prewarmPosts(_ ids: [PostID]) async
}

extension FeedFeatureBuilding {
    /// The ordinary case: a For You tab nobody is listening to.
    public func makeForYouViewController() -> UIViewController {
        makeForYouViewController(onTabPresentationChange: nil)
    }
}
