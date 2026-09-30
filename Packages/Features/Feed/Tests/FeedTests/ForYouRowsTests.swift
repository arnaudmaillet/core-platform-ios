import CoreModels
import DesignSystem
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

    private func makeList(_ kind: ForYouPostListViewController.Kind = .friends) -> ForYouPostListViewController {
        let list = ForYouPostListViewController(
            kind: kind,
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            videoPlayback: nil, staking: nil,
            header: PushedScreenHeader(wallet: nil, makeWalletSheet: nil, router: nil),
            openPost: nil
        )
        list.loadViewIfNeeded()
        list.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        return list
    }

    /// `[‹] ———— [points][search]` with no title at all (#323's large titles
    /// were taken back, 2026-09-30), no tab bar — the header every screen For
    /// You pushes wears. With nothing new
    /// the posts are ONE section, "Recent", titled (2026-09-30: Friends is
    /// usually all seen, and an untitled run made it a different screen from
    /// Following), in the order they came.
    @Test func aPushedListWearsTheSharedHeaderAndNoTabBar() {
        let list = makeList()
        #expect(list.hidesBottomBarWhenPushed)
        #expect(list.navigationItem.title == nil)
        #expect(list.navigationItem.largeTitleDisplayMode == .never)
        #expect(makeList(.following).navigationItem.title == nil)
        #expect(list.navigationItem.rightBarButtonItems?.map(\.identifier) == [
            PushedScreenHeader.searchItemIdentifier
        ])
        let posts = [post("a", by: "pal", at: 2), post("b", by: "pal", at: 1)]
        // Hosted, so "no header" is the layout's answer and not an off-screen
        // collection view's (see the sectioned test below).
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 4000))
        window.rootViewController = list
        window.isHidden = false
        defer { window.isHidden = true }
        list.render(.content(posts), newPosts: [])
        list.view.layoutIfNeeded()
        #expect(list.posts.map(\.id.rawValue) == ["a", "b"], "one after another, nothing regrouped")
        #expect(list.debugNewSectionCount == 0)
        let headers = list.debugSectionHeaders()
        #expect(headers.map { $0.title } == ["Recent"], "a lone Recent keeps its title")
        #expect(headers.map { $0.count } == [0])
    }

    /// "New" over the unseen, "Recent" over the rest (2026-09-29): the new
    /// rows lead, each half keeps the order it came in, and "New" carries the
    /// size of the set it was handed — the For You header's number.
    @Test func thePushedListLeadsWithItsNewPostsUnderACountedHeader() {
        let list = makeList(.following)
        let posts = [
            post("old-1", by: "bo", at: 5), post("new-1", by: "bo", at: 9),
            post("old-2", by: "cy", at: 4), post("new-2", by: "cy", at: 8)
        ]
        // In a WINDOW, tall enough for every row: a collection view off
        // screen realizes no supplementary views, so there would be no header
        // to read. Local, and hidden before it goes — a visible window held
        // past the test dies with the suite (`visible-window-suite-release`).
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 4000))
        window.rootViewController = list
        window.isHidden = false
        defer { window.isHidden = true }
        list.render(.content(posts), newPosts: [PostID("new-1"), PostID("new-2")])
        list.view.layoutIfNeeded()
        #expect(list.posts.map(\.id.rawValue) == ["new-1", "new-2", "old-1", "old-2"])
        #expect(list.debugNewSectionCount == 2)
        let headers = list.debugSectionHeaders()
        #expect(headers.map { $0.title } == ["New", "Recent"])
        #expect(headers.map { $0.count } == [2, 0], "only New is counted")
    }

    /// The app's ONE section spacing (2026-09-30): "Recent"'s title LINE
    /// stands `Spacing.section` under New's last card and `Spacing.sectionTitle`
    /// over its own first card — the distances the sound sheet and For You's
    /// rows keep.
    @Test func thePushedListKeepsTheAppsSectionSpacing() throws {
        let list = makeList(.following)
        let posts = [
            post("old-1", by: "bo", at: 5), post("new-1", by: "bo", at: 9),
            post("old-2", by: "cy", at: 4), post("new-2", by: "cy", at: 8)
        ]
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 4000))
        window.rootViewController = list
        window.isHidden = false
        defer { window.isHidden = true }
        list.render(.content(posts), newPosts: [PostID("new-1"), PostID("new-2")])
        list.view.layoutIfNeeded()
        func collectionView(in view: UIView) -> UICollectionView? {
            if let found = view as? UICollectionView { return found }
            return view.subviews.lazy.compactMap(collectionView(in:)).first
        }
        let collection = try #require(collectionView(in: list.view))
        collection.layoutIfNeeded()
        let layout = collection.collectionViewLayout
        let header = try #require(layout.layoutAttributesForSupplementaryView(
            ofKind: PostGridListLayout.headerElementKind, at: IndexPath(item: 0, section: 1)
        ))
        let lastNew = try #require(layout.layoutAttributesForItem(at: IndexPath(item: 1, section: 0)))
        let firstRecent = try #require(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 1)))
        let traits = collection.traitCollection
        let lineTop = header.frame.minY + SectionHeaderPillButton.inlineTitleTop(traits: traits)
        let line = UIFont.preferredFont(forTextStyle: .title3, compatibleWith: traits).lineHeight
        #expect(abs(lineTop - lastNew.frame.maxY - Spacing.section) <= 0.6,
                "Recent's line is \(lineTop - lastNew.frame.maxY) under New's last card")
        #expect(abs(firstRecent.frame.minY - (lineTop + line) - Spacing.sectionTitle) <= 0.6,
                "Recent's line is \(firstRecent.frame.minY - lineTop - line) over its first card")

        // And its title is the app's one section title, on the one line: the
        // header lies inside the cards' 16pt insets, the title stands 20 from
        // the list's edge like every other title (2026-09-30).
        let view = try #require(collection.supplementaryView(
            forElementKind: PostGridListLayout.headerElementKind, at: IndexPath(item: 0, section: 1)
        ) as? SectionHeaderCapsuleView)
        view.layoutIfNeeded()
        let title = view.debugPill.debugTitleView
        title.layoutIfNeeded()
        let titleX = title.convert(title.debugFrames.title, to: collection).minX
        #expect(abs(titleX - SectionTitleView.Metrics.surfaceInset) < 0.5, "Recent's title stands at \(titleX)")
    }

    /// A list that is ALL new is one section — "New", titled and counted, not
    /// the untitled run the inbox's rule would make it.
    @Test func aListThatIsAllNewIsOneCountedNewSection() {
        let list = makeList(.following)
        let posts = [post("n1", by: "bo", at: 2), post("n2", by: "bo", at: 1)]
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 4000))
        window.rootViewController = list
        window.isHidden = false
        defer { window.isHidden = true }
        list.render(.content(posts), newPosts: [PostID("n1"), PostID("n2")])
        list.view.layoutIfNeeded()
        #expect(list.debugNewSectionCount == 2)
        let headers = list.debugSectionHeaders()
        #expect(headers.map { $0.title } == ["New"])
        #expect(headers.map { $0.count } == [2])
    }

    /// An all-new list gaining its first older page grows a "Recent" section
    /// under "New" — a change of shape, so a reload rather than an insert (an
    /// insert into a section count that moved is UIKit's inconsistency crash).
    @Test func anAllNewListGainingAnOlderPageSplits() {
        let list = makeList(.friends)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 4000))
        window.rootViewController = list
        window.isHidden = false
        defer { window.isHidden = true }
        let first = [post("n1", by: "bo", at: 9), post("n2", by: "bo", at: 8)]
        list.render(.content(first), newPosts: [PostID("n1"), PostID("n2")])
        list.view.layoutIfNeeded()
        list.render(.content(first + [post("old", by: "cy", at: 1)]), newPosts: [PostID("n1"), PostID("n2")])
        list.view.layoutIfNeeded()
        #expect(list.posts.map(\.id.rawValue) == ["n1", "n2", "old"])
        #expect(list.debugSectionHeaders().map { $0.title } == ["New", "Recent"])
    }

    /// A post that stops being new (a friend's story watched while the list
    /// is up) goes back to its own place in "Recent", not to the top of it.
    @Test func aPostLeavingNewReturnsToItsPlace() {
        let list = makeList(.friends)
        let posts = [
            post("a", by: "ana", at: 9), post("b", by: "ana", at: 8),
            post("c", by: "dee", at: 7), post("d", by: "dee", at: 6)
        ]
        list.render(.content(posts), newPosts: [PostID("a"), PostID("c")])
        list.view.layoutIfNeeded()
        #expect(list.posts.map(\.id.rawValue) == ["a", "c", "b", "d"])
        list.render(.content(posts), newPosts: [PostID("a")])
        list.view.layoutIfNeeded()
        #expect(list.posts.map(\.id.rawValue) == ["a", "b", "c", "d"])
        #expect(list.debugNewSectionCount == 1)
    }

    /// An older page landing joins "Recent" and leaves "New" alone.
    @Test func aPageLandingJoinsRecent() {
        let list = makeList(.following)
        let first = [post("new", by: "bo", at: 9), post("old", by: "bo", at: 5)]
        list.render(.content(first), newPosts: [PostID("new")])
        list.view.layoutIfNeeded()
        list.render(.content(first + [post("older", by: "cy", at: 1)]), newPosts: [PostID("new")])
        list.view.layoutIfNeeded()
        #expect(list.posts.map(\.id.rawValue) == ["new", "old", "older"])
        #expect(list.debugNewSectionCount == 1)
    }

    // MARK: - The rows' view

    @Test func aRowWithNothingInItIsNotDrawn() {
        #expect(ForYouRailsView.height(forWidth: 393, friends: 0, following: 0) == 0)
        let both = ForYouRailsView.height(forWidth: 393, friends: 3, following: 3)
        let friendsOnly = ForYouRailsView.height(forWidth: 393, friends: 3, following: 0)
        #expect(friendsOnly > 0)
        #expect(both > friendsOnly)
    }

    /// The app's ONE section gap between the rows and before "For you"
    /// (2026-09-30): each title's line `Spacing.section` under the row above,
    /// the bar's own air counted in.
    @Test func theRowsKeepTheAppsSectionGap() {
        let width: CGFloat = 393
        let bar = SectionTitleView.Metrics.height
        let story = ForYouRailsView.Metrics.storySize(forWidth: width).height
        let card = ForYouRailsView.Metrics.cardSize(forWidth: width).height
        let gap = ForYouRailsView.Metrics.rowGap
        #expect(gap == SectionTitleView.gapAbove())
        let air = (bar - UIFont.systemFont(ofSize: 20, weight: .bold).lineHeight) / 2
        #expect(abs(gap + air - Spacing.section) <= 0.5)
        #expect(ForYouRailsView.height(forWidth: width, friends: 3, following: 3)
                == bar + story + gap + bar + card + gap + bar + ForYouRailsView.Metrics.listGap)
    }

    /// Two whole cards and a third peeking — the product's "the row goes on".
    @Test func aCardIsAFractionOfTheWidthSoTheThirdPeeks() {
        let width: CGFloat = 393
        let card = ForYouRailsView.Metrics.cardSize(forWidth: width)
        let margin = ForYouRailsView.Metrics.sideMargin
        let spacing = ForYouRailsView.Metrics.itemGap
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
