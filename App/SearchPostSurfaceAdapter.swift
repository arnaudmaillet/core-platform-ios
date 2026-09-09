import CoreModels
import FeedInterface
import Search
import UIKit

/// Lets the search results screen show the two post surfaces For You's tabs
/// are, without Search ever knowing Feed exists.
///
/// **A composition-root adapter rather than a dependency between the two
/// features** — the same shape, and the same reason, as
/// `ForYouExploreAdapter`. Search declares `SearchPostSurfaceProviding`; Feed
/// declares `PostSetSurface` through `FeedInterface`; the two vocabularies
/// meet here and nowhere else. Search gains no package dependency, and no code
/// moves between features.
///
/// ⚠️ THE TWO PROTOCOLS ARE DELIBERATELY NOT ONE. It is tempting to have
/// Search import `FeedInterface` and drop this file — `FeedInterface` is a
/// small interface package, not the 33,000-line feature. But the interface is
/// still the FEED's vocabulary: its surface talks about a set of posts, which
/// is a thing Feed knows how to draw, while Search's talks about the result of
/// a search, which is a thing Search knows how to produce. Naming each in its
/// own terms is what keeps either free to change without the other. The
/// translation below is four lines; that is the whole price.
struct SearchPostSurfaceAdapter: SearchPostSurfaceProviding {
    private let feed: any FeedFeatureBuilding

    init(feed: any FeedFeatureBuilding) {
        self.feed = feed
    }

    func makePostSurface(style: SearchPostSurfaceStyle) -> any SearchPostSurface {
        SurfaceBridge(
            surface: feed.makePostSetSurface(style: style == .gallery ? .gallery : .cards)
        )
    }

    /// One object wearing both protocols, so neither package has to know the
    /// other's.
    @MainActor
    private final class SurfaceBridge: SearchPostSurface {
        private let surface: any PostSetSurface

        init(surface: any PostSetSurface) {
            self.surface = surface
        }

        var viewController: UIViewController { surface.viewController }

        func show(_ state: SearchPostSurfaceState) {
            let translated: PostSetSurfaceState = switch state {
            case .loading: .loading
            case .posts(let ids): .posts(ids)
            // ⚠️ The people search's sentence is dropped on purpose. An empty
            // POST answer is not "no people matched" — the two searches are
            // separate and can disagree — and the surface draws its own empty
            // state for a set it was given nothing for.
            case .empty: .empty(message: "")
            case .failed(let message): .failed(message: message)
            }
            surface.show(translated)
        }
    }
}
