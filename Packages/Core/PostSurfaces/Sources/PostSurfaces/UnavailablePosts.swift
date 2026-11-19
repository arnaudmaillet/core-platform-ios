import CoreModels
import Foundation

/// The posts the server said this viewer may no longer see (#2048): a
/// window's hydration that answered GONE (`FixedPostsFeedProvider`), or a
/// comments panel's revalidation that answered not-found (#1409).
///
/// One per app (`AppContainer.unavailablePosts`, #2376), handed to every
/// feed and grid page: a post learnt unavailable on one surface leaves the others' pages
/// and tiles not yet shown. Only the page in front at the moment it is learnt
/// keeps "This post isn't available", until the viewer leaves it.
///
/// ⚠️ **FOR THIS VIEWER ONLY.** A viewer change forgets them all: a post
/// withheld from a guest (a private author) may be a member's to see. That is
/// why this is not `EntityStore.deletePost`, whose tombstones last the
/// session.
@MainActor
public final class UnavailablePosts {
    /// The app's viewer channel, whose viewer changes empty this record. The
    /// feed's comments panels follow a profile switch through it too, so the
    /// feed builder needs no channel of its own (#2376).
    public let viewerEvents: ViewerEvents

    private(set) var ids: Set<PostID> = []
    /// The surfaces holding posts, told of the ones just learnt, in the order
    /// they subscribed.
    private let changes = OrderedHandlers<Set<PostID>>()
    private var viewerSubscription: ViewerEventSubscription?

    /// `viewerEvents`: the app's one (#2376); a test's own, which it
    /// publishes on to change the viewer.
    public init(viewerEvents: ViewerEvents) {
        self.viewerEvents = viewerEvents
        viewerSubscription = viewerEvents.onViewerChange { [weak self] in
            self?.ids.removeAll()
        }
    }

    #if DEBUG
    /// How many surfaces hear this record's changes.
    var debugObservationCount: Int { changes.debugObservationCount }
    #endif

    public func contains(_ id: PostID) -> Bool { ids.contains(id) }

    /// Records `new`, and tells the surfaces holding any of them,
    /// synchronously, before it returns.
    public func insert(_ new: some Sequence<PostID>) {
        let added = Set(new).subtracting(ids)
        guard !added.isEmpty else { return }
        ids.formUnion(added)
        changes.send(added)
    }

    /// Calls `handler` with the posts each later `insert` learnt, until the
    /// subscription is cancelled or freed: keep it on the surface.
    public func onChange(_ handler: @escaping @MainActor (Set<PostID>) -> Void) -> ViewerEventSubscription {
        changes.subscribe(handler)
    }
}

/// A provider that learns which posts the server withholds — the window's
/// hydration (`FixedPostsFeedProvider.resolve`). The feed takes them after
/// each page, before it renders.
public protocol GonePostsReporting: Sendable {
    /// The posts answered GONE since the last call; forgotten once taken.
    func takeGoneIDs() async -> Set<PostID>
}
