import CoreModels
import UIKit

/// The two post surfaces the results screen shows, vended from outside Search.
///
/// ⚠️ **A SEAM RATHER THAN A DEPENDENCY, and the rule is the codebase's, not a
/// preference.** No feature package here imports another feature package —
/// eight `Features/*/Package.swift`, zero cross-feature edges — and
/// `App/ForYouExploreAdapter.swift` exists for the sole purpose of keeping
/// Search from importing Feed on behalf of this very screen. Search depending
/// on Feed would put ~34,000 lines in front of every search-screen build to
/// reuse two views.
///
/// So Search says what it needs, Feed already knows how to make it, and the
/// composition root joins them. The surfaces cross as opaque
/// `UIViewController`s: this package neither knows nor can know what a
/// `GalleryPost` is.
@MainActor
public protocol SearchPostSurfaceProviding: Sendable {
    /// A surface showing the posts a search matched.
    ///
    /// The caller owns WHERE it goes and WHICH posts; the surface owns what a
    /// post looks like and how to hydrate one. Both styles are the same
    /// component in this app — For You's Following and Discover tabs are one
    /// type in two styles — which is why this is one method with a parameter.
    func makePostSurface(style: SearchPostSurfaceStyle) -> any SearchPostSurface
}

/// A post surface, once made.
///
/// ⚠️ IDS CROSS, NOT POSTS. `search.v1` answers with references — a
/// `PostHit` carries an author, a thumbnail key and a date, and NO caption, no
/// attachments, no aspect ratio and no counts. A card cannot be drawn from
/// that, so whatever fills this seam has to hydrate the ids through `post.v1`
/// before it can render. Feed already owns the only path in this repo that
/// does (`FixedPostsFeedProvider` into `ForYouRepository.firstPage()`, plus one
/// batched counter read), which is the other half of why these surfaces are
/// vended rather than built here.
@MainActor
public protocol SearchPostSurface: AnyObject {
    /// The thing to put on screen.
    var viewController: UIViewController { get }
    /// What to show. Called again whenever the answer changes — a new query, a
    /// new order, a new scope.
    func show(_ state: SearchPostSurfaceState)

    /// Whether this surface is the tab the viewer is on. A surface one swipe
    /// away is laid out and must not be playing.
    func setPlaybackActive(_ active: Bool)
}

/// What a post surface is being asked to show.
public enum SearchPostSurfaceState: Equatable, Sendable {
    case loading
    /// The posts a search matched, in the order the engine ranked them.
    ///
    /// ⚠️ ORDER IS PART OF THE ANSWER. The surface must not re-rank: the sort
    /// the viewer picked was applied by the engine over the whole index, and a
    /// surface reordering the page it was handed would show a different answer
    /// under the same label.
    case posts([PostID])
    case empty(query: String)
    case failed(message: String)
}

/// Which of the two the caller wants.
public enum SearchPostSurfaceStyle: Sendable {
    /// Full-width cards, the shape For You's "Following" tab reads in.
    case cards
    /// A media gallery, the shape For You's "Discover" tab reads in.
    case gallery
}
