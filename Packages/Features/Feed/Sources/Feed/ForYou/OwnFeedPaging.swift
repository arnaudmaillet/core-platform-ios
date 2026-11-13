import CoreModels
import PostGrid

/// The Discover gallery's "own feed" (#2379, stage A2): the opening that
/// reads For You's own list ahead instead of replaying the grid's window. The
/// gallery receives it as this protocol, so it can leave Feed without the
/// data layer `ForYouOwnFeed` reads (`ForYouDiscovery`, `FeedLocalCache`).
@MainActor
protocol OwnFeedPaging: AnyObject {
    /// The posts to open on, starting at `tapped`; nil to keep the grid's
    /// window.
    func begin(with tapped: GalleryPost) -> [GalleryPost]?
    /// The next window past `after`; `[]` for "nothing yet", nil at the end.
    func next(after: PostID) async -> [PostID]?
    /// The opening closed.
    func end()
}
