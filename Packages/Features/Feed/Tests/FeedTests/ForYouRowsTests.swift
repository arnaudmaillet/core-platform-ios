import CoreModels
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// For You's two rows (2026-09-29): Friends as stories, the rest of the
/// people the viewer follows as cards — their ordering rules, the ring that a
/// viewing clears, and the screens their headers push.
@MainActor
struct ForYouRowsTests {
    private func post(
        _ id: String, by author: String, at publishedAtMS: Int64, kind: GalleryPost.Kind = .photo
    ) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: kind, isRepost: false,
            thumbnailURL: kind == .text ? nil : URL(string: "https://example.com/\(id).jpg"),
            caption: "caption \(id)", publishedAtMS: publishedAtMS,
            authorID: ProfileID(author), authorName: author.capitalized, authorHandle: author
        )
    }

    // MARK: - The pure ordering

    /// Unseen first on both rows; the newest first inside each half.
    @Test func unseenLeadsBothRows() {
        let following = [
            post("old", by: "bo", at: 10), post("new", by: "bo", at: 30), post("mid", by: "cy", at: 20)
        ]
        let friends = [
            post("ana-old", by: "ana", at: 5),
            post("dee-new", by: "dee", at: 40), post("dee-newer", by: "dee", at: 50),
            post("eve-recent", by: "eve", at: 60)
        ]
        let rails = ForYouViewModel.rails(
            following: following, followingNew: [PostID("new")],
            friends: friends, friendsUnseen: [PostID("dee-new"), PostID("dee-newer")],
            limit: 20
        )
        #expect(rails.following.map(\.id.rawValue) == ["new", "mid", "old"])
        // Dee has unseen posts: first, ringed, opening onto ONLY those.
        #expect(rails.friends.map(\.handle) == ["dee", "eve", "ana"])
        #expect(rails.friends[0].hasUnseen)
        #expect(rails.friends[0].posts.map(\.id.rawValue) == ["dee-newer", "dee-new"])
        // Nothing unseen: no ring, and a tap opens their recent posts.
        #expect(!rails.friends[1].hasUnseen)
        #expect(rails.friends[1].posts.map(\.id.rawValue) == ["eve-recent"])
    }

    @Test func theRowsAreCapped() {
        let many = (0..<30).map { post("p\($0)", by: "bo", at: Int64($0)) }
        let rails = ForYouViewModel.rails(
            following: many, followingNew: [], friends: many, friendsUnseen: [], limit: 20
        )
        #expect(rails.following.count == 20)
        #expect(rails.friends.first?.posts.count == 20)
    }

    // MARK: - The ring clears once viewed

    /// A friend's new post rings their avatar; once its story has been viewed
    /// the ring clears and the friend joins the ones after — across a relaunch
    /// too, since the store persists.
    @Test func viewingAStoryClearsItsRing() async {
        let suite = "foryou.rows.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let unread = ForYouUnreadStore(defaults: defaults, keyPrefix: "rows.unread", arguments: [])
        unread.markSeen(.activity, in: [post("seed", by: "x", at: 1)])
        let posts = [post("pal-new", by: "pal", at: 100), post("amy-new", by: "amy", at: 90)]
        func makeModel() -> ForYouViewModel {
            ForYouViewModel(
                repository: RowsStubProvider(posts: posts),
                unreadStore: unread,
                seenStore: ForYouSeenPostsStore(defaults: defaults, key: "rows.seen"),
                followRelations: MutualRelations(friends: ["pal", "amy"])
            )
        }
        let model = makeModel()
        var latest: ForYouViewModel.Snapshot?
        model.onSnapshotChange = { latest = $0 }
        model.viewDidLoad()
        for _ in 0..<80 where latest?.rails.friends.isEmpty ?? true {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(latest?.rails.friends.map(\.handle) == ["pal", "amy"])
        #expect(latest?.rails.friends.allSatisfy(\.hasUnseen) == true)
        #expect(latest?.rails.friendsBadge == 2)

        model.markStoryPostsSeen([PostID("pal-new")])
        #expect(latest?.rails.friends.map(\.handle) == ["amy", "pal"], "viewed friends go after")
        #expect(latest?.rails.friends.last?.hasUnseen == false)
        #expect(latest?.rails.friendsBadge == 1)
        #expect(latest?.friendsUnseen == [PostID("amy-new")])
    }

    @Test func theSeenStoreKeepsTheNewestAndReportsNews() {
        let suite = "foryou.seen.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ForYouSeenPostsStore(defaults: defaults, key: "k", capacity: 2)
        #expect(store.insert([PostID("a"), PostID("b")]))
        #expect(store.insert([PostID("a")]) == false, "nothing new, nothing to republish")
        #expect(store.insert([PostID("c")]))
        #expect(!store.contains(PostID("a")), "the oldest fell off")
        #expect(ForYouSeenPostsStore(defaults: defaults, key: "k").contains(PostID("c")))
    }

    // MARK: - The pushed lists

    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    /// `[‹] ———— [points][search]`, no tab bar — the header every screen For
    /// You pushes wears — over a plain run of posts: no "New" and "Recent"
    /// halves (2026-09-29), the order they came in.
    @Test func aPushedListWearsTheSharedHeaderAndNoTabBar() {
        let list = ForYouPostListViewController(
            kind: .friends,
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            videoPlayback: nil, staking: nil,
            header: PushedScreenHeader(wallet: nil, makeWalletSheet: nil, router: nil),
            openPost: nil
        )
        list.loadViewIfNeeded()
        #expect(list.hidesBottomBarWhenPushed)
        #expect(list.title == nil)
        #expect(list.navigationItem.rightBarButtonItems?.map(\.identifier) == [
            PushedScreenHeader.searchItemIdentifier
        ])
        let posts = [post("a", by: "pal", at: 2), post("b", by: "pal", at: 1)]
        list.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        list.render(.content(posts))
        list.view.layoutIfNeeded()
        #expect(list.posts.map(\.id.rawValue) == ["a", "b"], "one after another, nothing regrouped")
    }

    // MARK: - The rows' view

    @Test func aRowWithNothingInItIsNotDrawn() {
        #expect(ForYouRailsView.height(forWidth: 393, friends: 0, following: 0) == 0)
        let both = ForYouRailsView.height(forWidth: 393, friends: 3, following: 3)
        let friendsOnly = ForYouRailsView.height(forWidth: 393, friends: 3, following: 0)
        #expect(friendsOnly > 0)
        #expect(both > friendsOnly)
    }

    /// Two whole cards and a third peeking — the product's "the row goes on".
    @Test func aCardIsAFractionOfTheWidthSoTheThirdPeeks() {
        let width: CGFloat = 393
        let card = ForYouRailsView.Metrics.cardSize(forWidth: width)
        let margin = ForYouRailsView.Metrics.sideMargin
        let spacing = ForYouRailsView.Metrics.cardSpacing
        let twoCards = margin + card.width * 2 + spacing * 2
        #expect(twoCards < width, "a third card starts on screen")
        #expect(twoCards + card.width > width, "and does not fit")
        #expect(card.height > card.width, "portrait")
    }
}

private struct MutualRelations: SocialGraphReading {
    let friends: Set<String>
    func followRelation(to profileID: ProfileID) async throws -> FollowRelation {
        friends.contains(profileID.rawValue) ? .mutual : .following
    }
}

private final class RowsStubProvider: ForYouProviding, @unchecked Sendable {
    private let posts: [GalleryPost]
    init(posts: [GalleryPost]) { self.posts = posts }
    func firstPage() async throws -> ForYouPage { ForYouPage(posts: posts, nextPageToken: nil) }
    func page(after token: String) async throws -> ForYouPage {
        ForYouPage(posts: [], nextPageToken: nil)
    }
}
