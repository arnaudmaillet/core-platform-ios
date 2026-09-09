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
    /// The caller owns WHERE it goes; the surface owns what a post looks like.
    /// Both styles are the same component in this app — For You's Following and
    /// Discover tabs are one type in two styles — which is why this is one
    /// method with a parameter rather than two.
    func makePostSurface(style: SearchPostSurfaceStyle) -> UIViewController
}

/// Which of the two the caller wants.
public enum SearchPostSurfaceStyle: Sendable {
    /// Full-width cards, the shape For You's "Following" tab reads in.
    case cards
    /// A media gallery, the shape For You's "Discover" tab reads in.
    case gallery
}
