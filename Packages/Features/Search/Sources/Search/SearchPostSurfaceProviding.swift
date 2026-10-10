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

    /// Called as the viewer nears the end of what is shown: the cue to fetch
    /// the next page and show the longer list, which is appended (#579).
    var onNearEnd: (() -> Void)? { get set }

    /// The failed state's Try Again was pressed (#798): the cue to ask
    /// again for what failed. Without it the button had nothing behind it.
    var onRetry: (() -> Void)? { get set }

    /// The footer spinner, while a next page is fetched.
    func setPaging(_ paging: Bool)

    /// Whether there is another page past what was shown, so a post opened
    /// from this surface can page on into it (#638).
    func setHasMore(_ hasMore: Bool)

    /// `.discover` only (#629): a row of cards above the list — For You's
    /// "Following" slot — showing these posts in this order.
    func showLeadRow(_ state: SearchPostSurfaceState)
    /// `.discover` only: what the lead row and the list are titled.
    func setSectionTitles(row: String, list: String)
    /// `.discover` only: the lead row's title was tapped.
    var onLeadRowTitleTapped: (() -> Void)? { get set }
}

public extension SearchPostSurface {
    var onNearEnd: (() -> Void)? {
        get { nil }
        set {}
    }

    var onRetry: (() -> Void)? {
        get { nil }
        set {}
    }

    func setPaging(_ paging: Bool) {}
    func setHasMore(_ hasMore: Bool) {}
    func showLeadRow(_ state: SearchPostSurfaceState) {}
    func setSectionTitles(row: String, list: String) {}
    var onLeadRowTitleTapped: (() -> Void)? {
        get { nil }
        set {}
    }
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

/// Which shape the caller wants.
public enum SearchPostSurfaceStyle: Sendable {
    /// Full-width cards, the shape For You's "Following" list reads in.
    case cards
    /// For You's own page (#629): cards with slices of the media mosaic
    /// between them, "View all" into the media gallery, and an optional row
    /// of cards above (`showLeadRow`).
    case discover
}
