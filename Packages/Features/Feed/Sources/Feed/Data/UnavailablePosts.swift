import AuthInterface
import CoreModels
import Foundation

/// The posts the server said this viewer may no longer see (#2048): a
/// window's hydration that answered GONE (`FixedPostsFeedProvider`), or a
/// comments panel's revalidation that answered not-found (#1409).
///
/// One per app (`FeedFeatureBuilder`), shared by every feed and the For You
/// grid: a post learnt unavailable on one surface leaves the others' pages
/// and tiles not yet shown. Only the page in front at the moment it is learnt
/// keeps "This post isn't available", until the viewer leaves it.
///
/// ⚠️ **FOR THIS VIEWER ONLY.** A viewer change forgets them all: a post
/// withheld from a guest (a private author) may be a member's to see. That is
/// why this is not `EntityStore.deletePost`, whose tombstones last the
/// session.
@MainActor
public final class UnavailablePosts {
    /// The app's one record. A test builds its own.
    static let shared = UnavailablePosts()

    /// Posted with the posts just learnt under `idsKey`.
    static let didChange = Notification.Name("UnavailablePostsDidChange")
    static let idsKey = "ids"

    private(set) var ids: Set<PostID> = []
    private let viewerObservation = NotificationTokens()

    init() {
        viewerObservation.add(NotificationCenter.default.addObserver(forName: .viewerDidChange, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.ids.removeAll() }
        })
    }

    func contains(_ id: PostID) -> Bool { ids.contains(id) }

    /// Records `new`, and tells the surfaces holding any of them.
    func insert(_ new: some Sequence<PostID>) {
        let added = Set(new).subtracting(ids)
        guard !added.isEmpty else { return }
        ids.formUnion(added)
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: [Self.idsKey: added])
    }
}

/// A provider that learns which posts the server withholds — the window's
/// hydration (`FixedPostsFeedProvider.resolve`). The feed takes them after
/// each page, before it renders.
protocol GonePostsReporting: Sendable {
    /// The posts answered GONE since the last call; forgotten once taken.
    func takeGoneIDs() async -> Set<PostID>
}
