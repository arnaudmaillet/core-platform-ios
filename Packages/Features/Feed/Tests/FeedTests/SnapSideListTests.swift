import CoreContracts
import CoreModels
import CoreNavigation
import Foundation
import MediaCore
import MediaPlayback
import PostGrid
import Testing
import UIKit
@testable import Feed

/// The side list (#1425), on every vertical feed since #1473.
@MainActor
struct SnapSideListTests {
    // MARK: - Geometry

    /// The page's open card, on screen, from the pager's transform.
    private static func card(_ geometry: SnapSideList.Geometry, progress: CGFloat = 1) -> CGRect {
        let size = geometry.size
        return CGRect(origin: .zero, size: size).applying(
            CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2)
                .concatenating(geometry.pagerTransform(progress: progress))
                .concatenating(CGAffineTransform(translationX: size.width / 2, y: size.height / 2))
        )
    }

    /// The bars as the two simulators wear them: an iPhone 18 Pro (402 × 874)
    /// and an iPhone SE, 2nd generation (375 × 667).
    static let devices: [(size: CGSize, bars: UIEdgeInsets)] = [
        (CGSize(width: 402, height: 874), UIEdgeInsets(top: 116, left: 0, bottom: 98, right: 0)),
        (CGSize(width: 375, height: 667), UIEdgeInsets(top: 64, left: 0, bottom: 49, right: 0)),
    ]

    /// ⚠️ BETWEEN THE BARS (#1509): open, the card and the list sit entirely
    /// between the top bar and the bottom toolbar, a gap from each; the
    /// card keeps one gap from the leading edge and one from the list, which
    /// keeps one from the trailing edge; closed, nothing moved.
    @Test(arguments: [0, 1])
    func theCardAndTheListShareTheScreen(_ device: Int) {
        let (size, bars) = Self.devices[device]
        let geometry = SnapSideList.Geometry(size: size, bars: bars, deviceCornerRadius: 55)
        let gap = SnapSideList.Geometry.gap
        #expect(geometry.pagerTransform(progress: 0) == .identity)

        let card = Self.card(geometry)
        let list = geometry.listFrame(progress: 1)
        #expect(card.minY >= bars.top + gap - 0.01, "the card runs under the top bar: \(card)")
        #expect(card.maxY <= size.height - bars.bottom - gap + 0.01, "the card runs under the toolbar: \(card)")
        #expect(abs(card.width / card.height - size.width / size.height) < 0.001, "the card does not keep the page's aspect")
        #expect(abs(card.minX - gap) < 0.01, "the card's leading gap: \(card)")
        #expect(abs(list.minX - card.maxX - gap) < 0.01, "the gap between card and list: \(card) \(list)")
        #expect(abs(size.width - list.maxX - gap) < 0.01, "the list's trailing gap: \(list)")
        #expect(abs(list.height - card.height) < 0.01 && abs(list.minY - card.minY) < 0.01, "the list is not the card's height")
        #expect(geometry.listFrame(progress: 0).minX == size.width, "closed, the list waits beyond the edge")
        // Never under a bar at any progress past 0 (the list's own frame
        // slides in from beyond the edge, at the open card's height).
        for progress in stride(from: 0.1, through: 1, by: 0.1) {
            let moving = geometry.listFrame(progress: progress)
            #expect(moving.minY >= bars.top && moving.maxY <= size.height - bars.bottom)
        }
    }

    /// The list is wider than the old ninth on an 18 Pro (about 70 pt), and
    /// never narrower than its minimum on an SE.
    @Test func theListTakesTheWidthTheCardLeaves() {
        let pro = SnapSideList.Geometry(size: Self.devices[0].size, bars: Self.devices[0].bars)
        #expect(pro.listWidth > 60 && pro.listWidth < 100, "\(pro.listWidth)")
        let se = SnapSideList.Geometry(size: Self.devices[1].size, bars: Self.devices[1].bars)
        #expect(se.listWidth >= SnapSideList.Geometry.minimumListWidth)
    }

    /// ⚠️ THE CORNERS GO FROM THE DEVICE'S TO THE CARD'S (#1509), in screen
    /// space and continuously — never square.
    @Test func theCornersGoFromTheDevicesToTheCards() {
        let geometry = SnapSideList.Geometry(size: Self.devices[0].size, bars: Self.devices[0].bars, deviceCornerRadius: 55)
        let card = SnapSideList.Geometry.cornerRadius
        #expect(card == SnapSideList.Geometry.tileCornerRadius, "the tiles' corner is not the card's (#1527)")
        #expect(geometry.screenCornerRadius(progress: 0) == 55)
        #expect(abs(geometry.screenCornerRadius(progress: 0.5) - (55 + card) / 2) < 0.01)
        #expect(geometry.screenCornerRadius(progress: 1) == card)
    }

    /// ⚠️ THE OVERLAY MOVES DOWN WITH THE SLIDE (#1509) by the band the
    /// toolbar covers, and back up on close.
    @Test func theOverlayMovesDownByTheToolbarsBand() {
        let geometry = SnapSideList.Geometry(size: Self.devices[0].size, bars: Self.devices[0].bars)
        #expect(geometry.overlayOffset(progress: 0) == 0)
        #expect(geometry.overlayOffset(progress: 0.5) == Self.devices[0].bars.bottom / 2)
        #expect(geometry.overlayOffset(progress: 1) == Self.devices[0].bars.bottom)
    }

    /// Past half way, or flung, it opens; short of it, it springs back.
    @Test func aReleaseSettlesByWhereItWouldCarryOnTo() {
        let geometry = SnapSideList.Geometry(size: CGSize(width: 402, height: 874))
        #expect(geometry.settlesOpen(progress: 0.6, velocityX: 0))
        #expect(!geometry.settlesOpen(progress: 0.3, velocityX: 0))
        #expect(geometry.settlesOpen(progress: 0.3, velocityX: -900), "a leftward flick opens")
        #expect(!geometry.settlesOpen(progress: 0.7, velocityX: 900), "a rightward flick closes")
    }

    // MARK: - The screen

    private static func photo(_ id: String) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("a"), authorName: "Ava", metaText: "",
            avatarURL: nil, caption: "", mediaURL: URL(string: "https://example.test/\(id).jpg"), mediaKind: .image,
            thumbnailURL: nil, audioText: nil
        )
    }

    private static func entry(_ id: String, media: Bool = true) -> FeedEntry {
        FeedEntry(
            post: Post(
                id: PostID(id), authorID: ProfileID("author-\(id)"), caption: "caption \(id)",
                attachments: media ? [MediaAttachment(
                    url: URL(string: "https://cdn.example/\(id).jpg"), thumbnailURL: nil,
                    mimeType: "image/jpeg", pixelWidth: 1080, pixelHeight: 1350
                )] : [],
                publishedAt: Date(timeIntervalSince1970: 1_760_000_000), likeCountsHidden: false
            ),
            author: AuthorSummary(id: ProfileID("author-\(id)"), handle: "h-\(id)", displayName: "Name \(id)", avatarURL: nil),
            likeCount: 0
        )
    }

    private func feed(sideList: Bool) -> SnapFeedViewController {
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: SideListProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            reporting: SideListReporter()
        )
        controller.installsSideList = sideList
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.seedProjection([Self.photo("p1")])
        controller.view.layoutIfNeeded()
        return controller
    }

    /// On by default (#1473): a vertical feed installs it with no flag.
    @Test func everyVerticalFeedInstallsItByDefault() {
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: SideListProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            reporting: SideListReporter()
        )
        #expect(controller.installsSideList)
    }

    /// A screen that opts out installs nothing, and the dismissal answers as
    /// it always did.
    @Test func aScreenThatOptsOutInstallsNothing() {
        let feed = feed(sideList: false)
        #expect(feed.sideList == nil)
        #expect(!feed.view.subviews.contains { $0 is SnapSideListView })
        #expect(feed.isReadyForInteractiveDismissal)
    }

    /// Open: the pager is a card, the list is on screen, the dismissals stand
    /// aside and the pager pages back; closed, all of it undone.
    @Test func openingShrinksThePagerAndHoldsTheDismissals() throws {
        let feed = feed(sideList: true)
        let sideList = try #require(feed.sideList)
        let pager = try #require(feed.collectionView as? SnapFeedCollectionView)

        sideList.settle(open: true, animated: false)
        #expect(pager.transform != .identity, "the page did not shrink")
        #expect(pager.layer.cornerRadius > 0, "the open card is square")
        #expect(pager.transform.a < 1 && pager.transform.a == pager.transform.d, "not one uniform scale")
        #expect(feed.view.transform == .identity, "the screen itself moved")
        #expect(!sideList.listView.isHidden)
        #expect(!feed.isReadyForInteractiveDismissal, "a dismissal could begin while the list is open")
        #expect(pager.allowsBackwardPaging, "the pager does not page back while open")

        sideList.settle(open: false, animated: false)
        #expect(pager.transform == .identity)
        #expect(feed.collectionView.visibleCells.compactMap { ($0 as? SnapFeedCell)?.sideListOverlayOffset }.allSatisfy { $0 == 0 },
                "an overlay stayed down after the close")
        #expect(sideList.listView.isHidden)
        #expect(feed.isReadyForInteractiveDismissal)
        #expect(!pager.allowsBackwardPaging)
    }

    // MARK: - Autoplay (#1509)

    private struct StubSource: VideoSource {
        func playableURL(for url: URL) async throws -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("stub.mp4")
        }
    }

    private static func clip(_ id: String) -> FeedEntry {
        FeedEntry(
            post: Post(
                id: PostID(id), authorID: ProfileID("author-\(id)"), caption: "",
                attachments: [MediaAttachment(
                    url: URL(string: "mock://video/side-\(id)"), thumbnailURL: nil,
                    mimeType: "video/mp4", pixelWidth: 1080, pixelHeight: 1920
                )],
                publishedAt: Date(timeIntervalSince1970: 1_760_000_000), likeCountsHidden: false
            ),
            author: AuthorSummary(id: ProfileID("author-\(id)"), handle: "h", displayName: "N", avatarURL: nil),
            likeCount: 812
        )
    }

    /// ⚠️ THE LIST'S VIDEO TILES PLAY WHILE IT IS OPEN, AND ONLY THEN (#1509,
    /// the owner's choice): muted, on the app's pool, within the shared
    /// ranking's budget; closed, every tile gives its player back.
    @Test func theListsVideoTilesPlayWhileItIsOpen() async throws {
        let pool = VideoPlaybackController(source: StubSource(), poolSize: 6)
        let list = SnapSideListView(imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
        list.autoplay = SnapSideListAutoplay(pool: pool, imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
        list.frame = CGRect(x: 0, y: 0, width: 80, height: 600)
        list.layoutIfNeeded()
        list.show((0..<6).map { Self.clip("v\($0)") })
        let cells = list.debugTileCells
        #expect(cells.count >= 3, "guard: tiles on screen")
        #expect(cells.allSatisfy { $0.loadedVideoRenderView == nil }, "a tile played while the list was closed")

        // A tile plays once its poster is up (the galleries' rule).
        for _ in 0..<600 where !cells.allSatisfy({ $0.renderedCover != nil }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(cells.allSatisfy { $0.renderedCover != nil }, "guard: the covers landed")
        var waited = 0
        while !GridVideoPlaybackCoordinator.allowsAutoplay(), waited < 400 {
            waited += 1
            try? await Task.sleep(for: .milliseconds(5))
        }
        list.setPlaying(true)
        let started = cells.filter { $0.loadedVideoRenderView != nil }.count
        #expect(started > 0 && started <= SnapSideListAutoplay.concurrentPlayers, "\(started) tiles started")
        #expect(cells.allSatisfy { $0.isCompact }, "a side-list tile kept the grid's counter")

        list.setPlaying(false)
        #expect(list.autoplay?.playback.isPlaying(PostID("v0")) != true, "a tile kept playing once closed")
    }

    /// ⚠️ THE POST ON SHOW FIRST, THEN SIMILAR POSTS (#1509): current posts
    /// of the feed's kind, none already in it, once each — and the same
    /// list again for the same anchor.
    @Test func theListIsThePostOnShowThenOthersOfTheFeedsKind() async {
        let feed = feed(sideList: true)
        var asked = 0
        feed.sideListEntries = {
            asked += 1
            return [Self.entry("p1"), Self.entry("m1"), Self.entry("t1", media: false), Self.entry("m2"), Self.entry("m1")]
        }
        let ids = await feed.sideListCandidates().map(\.post.id.rawValue)
        #expect(ids.first == "p1", "the post on show is not first: \(ids)")
        #expect(Set(ids.dropFirst()) == ["m1", "m2"] && ids.count == 3, "not the other media posts, once each: \(ids)")
        #expect(await feed.sideListCandidates().map(\.post.id.rawValue) == ids, "a new list for the same anchor")
        #expect(asked == 1)
    }

    /// A feed of `ids`, the side list installed, its "similar posts" `others`.
    private func openableFeed(
        _ ids: [String], others: [String], text: Set<String> = [], router: (any Router)? = nil
    ) async throws -> SnapFeedViewController {
        let controller = SnapFeedViewController(
            // Its first page IS the feed: a seed alone is replaced by the
            // first page when it lands.
            viewModel: FeedViewModel(
                repository: PostsProvider(entries: ids.map { Self.entry($0, media: !text.contains($0)) }), router: router
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            reporting: SideListReporter()
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.layoutIfNeeded()
        controller.sideListEntries = { others.map { Self.entry($0) } }
        try #require(await settle { controller.orderedIDs.map(\.rawValue) == ids }, "guard: the feed's first page")
        controller.view.layoutIfNeeded()
        return controller
    }

    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<600 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        return condition()
    }

    func openableFeedForChain(
        _ ids: [String], others: [String] = [], text: Set<String> = [], router: (any Router)?
    ) async throws -> SnapFeedViewController {
        let feed = try await openableFeed(ids, others: others, text: text, router: router)
        // The chain reads the post on show: settled under a loaded suite too.
        try #require(await settle { feed.activePostID == PostID(ids[0]) && !feed.collectionView.isDecelerating },
                     "guard: the first post on show")
        return feed
    }

    func openForChain(_ feed: SnapFeedViewController) async throws -> SnapSideListController {
        try await open(feed)
    }

    /// Opens `feed`'s list on the post on show and waits for it to drive the card.
    private func open(_ feed: SnapFeedViewController) async throws -> SnapSideListController {
        let sideList = try #require(feed.sideList)
        sideList.loadIfNeeded()
        try #require(await settle { !sideList.listView.entries.isEmpty }, "the list never loaded")
        sideList.settle(open: true, animated: false)
        try #require(await settle { feed.isSideListSessionActive }, "the list does not drive the card")
        return sideList
    }

    /// ⚠️ WHILE OPEN, THE CARD PAGES THROUGH THE LIST (#1509, the owner's
    /// choice): the feed's pages are the list's — the post on show first —
    /// and the feed is set aside, nothing injected into it; the post on show
    /// wears the tint border.
    @Test func whileOpenTheCardPagesThroughTheList() async throws {
        let feed = try await openableFeed(["p1", "p2"], others: ["m1", "m2"])
        let sideList = try await open(feed)
        let list = sideList.listView.entries.map(\.post.id)
        #expect(feed.orderedIDs == list, "the card does not page through the list: \(feed.orderedIDs) vs \(list)")
        #expect(feed.activePostID == PostID("p1"), "the card left the post on show")
        #expect(sideList.listView.outlinedPostID == PostID("p1"))
        #expect(!feed.orderedIDs.contains(PostID("p2")), "the feed's own posts are mixed into the list")
    }

    /// ⚠️ A RIGHTWARD CLOSE MID-LIST KEEPS THE POST ON SHOW (#1509): the feed
    /// comes back as it was, that post right after the anchor, the pager on
    /// it — the next swipe up continues the feed after the anchor.
    @Test func aCloseMidListKeepsThePostOnShowAfterTheAnchor() async throws {
        let feed = try await openableFeed(["p1", "p2"], others: ["m1", "m2"])
        let sideList = try await open(feed)
        let picked = try #require(feed.orderedIDs.last)
        feed.settlePager(onIndex: feed.orderedIDs.count - 1)
        #expect(feed.activePostID == picked, "guard: the card is on the list's last post")

        sideList.settle(open: false, animated: false)
        #expect(!feed.isSideListSessionActive)
        #expect(feed.orderedIDs == [PostID("p1"), picked, PostID("p2")], "not placed right after the anchor: \(feed.orderedIDs)")
        #expect(feed.activePostID == picked, "the post on show did not stay full screen")
    }

    /// ⚠️ PAST THE LIST'S LAST TILE, A SWIPE UP CLOSES THE LIST (#1509) and
    /// lands on the feed's post after the anchor — the feed untouched.
    @Test func aSwipeUpPastTheLastTileClosesTheListOntoTheFeed() async throws {
        let feed = try await openableFeed(["p1", "p2"], others: ["m1", "m2"])
        _ = try await open(feed)
        feed.settlePager(onIndex: feed.orderedIDs.count - 1)
        let pager = try #require(feed.collectionView)
        var target = pager.contentOffset
        withUnsafeMutablePointer(to: &target) { pointer in
            feed.scrollViewWillEndDragging(pager, withVelocity: CGPoint(x: 0, y: 2), targetContentOffset: pointer)
        }
        #expect(!feed.isSideListSessionActive, "the list stayed open past its last tile")
        #expect(feed.orderedIDs == [PostID("p1"), PostID("p2")], "the list leaked into the feed: \(feed.orderedIDs)")
        #expect(feed.activePostID == PostID("p2"), "not the post after the anchor")
    }

    /// Closed on the post it was opened from: the feed exactly as it was.
    @Test func aCloseOnTheAnchorRestoresTheFeedUntouched() async throws {
        let feed = try await openableFeed(["p1", "p2"], others: ["m1", "m2"])
        let sideList = try await open(feed)
        sideList.settle(open: false, animated: false)
        #expect(feed.orderedIDs == [PostID("p1"), PostID("p2")])
        #expect(feed.activePostID == PostID("p1"))
    }
}

/// The leftward swipe chain on the vertical feed (#1525): the side list on a
/// media post, the author's profile on a text post and past the open list.
@MainActor
struct SnapSwipeChainTests {
    /// Makes a profile screen for every `.profile` route, and records them.
    @MainActor
    final class ProfileRouter: Router {
        var made: [ProfileID] = []
        func route(to route: AppRoute) {}
        func destination(for route: AppRoute) -> UIViewController? {
            guard case .profile(let id, _) = route else { return nil }
            made.append(id)
            let screen = UIViewController()
            screen.title = id.rawValue
            return screen
        }
    }

    private let tests = SnapSideListTests()

    private func center(of feed: SnapFeedViewController) -> CGPoint {
        CGPoint(x: feed.view.bounds.midX - 40, y: feed.view.bounds.midY)
    }

    private static func isPanel(_ stage: SwipeStage?) -> Bool {
        if case .panel = stage { return true }
        return false
    }

    private static func pushed(_ stage: SwipeStage?) -> UIViewController? {
        if case .push(let make) = stage { return make() }
        return nil
    }

    /// A media post, the list closed: leftward opens the list; rightward is
    /// not the chain's (the dismissal's).
    @Test func aMediaPostsLeftwardOpensTheList() async throws {
        let feed = try await tests.openableFeedForChain(["p1", "p2"], router: ProfileRouter())
        #expect(Self.isPanel(feed.swipeStage(for: .leftward, at: center(of: feed))))
        #expect(feed.swipeStage(for: .rightward, at: center(of: feed)) == nil)
    }

    /// ⚠️ A TEXT POST HAS NO LIST (#1525, the owner): leftward pushes the
    /// author's profile.
    @Test func aTextPostsLeftwardPushesTheAuthor() async throws {
        let router = ProfileRouter()
        let feed = try await tests.openableFeedForChain(["t1", "p2"], text: ["t1"], router: router)
        let stage = feed.swipeStage(for: .leftward, at: center(of: feed))
        #expect(!Self.isPanel(stage), "a text post opened the side list")
        let profile = try #require(Self.pushed(stage))
        #expect(profile.title == "author-t1", "not the post's author")
    }

    /// ⚠️ WITH THE LIST OPEN, LEFTWARD PUSHES THE CARD'S AUTHOR — the post on
    /// show, the list's current item, not the anchor's; rightward closes.
    @Test func withTheListOpenLeftwardPushesTheShownPostsAuthor() async throws {
        let feed = try await tests.openableFeedForChain(["p1", "p2"], others: ["m1", "m2"], router: ProfileRouter())
        let sideList = try await tests.openForChain(feed)
        feed.settlePager(onIndex: feed.orderedIDs.count - 1)
        let shown = try #require(feed.activePostID)
        #expect(shown != PostID("p1"), "guard: the card moved off the anchor")
        let profile = try #require(Self.pushed(feed.swipeStage(for: .leftward, at: CGPoint(x: 60, y: feed.view.bounds.midY))))
        #expect(profile.title == "author-\(shown.rawValue)", "not the shown post's author")
        #expect(Self.isPanel(feed.swipeStage(for: .rightward, at: center(of: feed))), "rightward does not close the list")
        _ = sideList
    }

    /// ⚠️ BACK FROM THE PROFILE, THE POST IS FULL SCREEN (#1525): a committed
    /// push closes the list behind it, the post on show placed after the
    /// anchor; a cancelled one leaves the list open.
    @Test func aCommittedPushClosesTheListBehindTheProfile() async throws {
        let feed = try await tests.openableFeedForChain(["p1", "p2"], others: ["m1", "m2"], router: ProfileRouter())
        let sideList = try await tests.openForChain(feed)
        feed.settlePager(onIndex: feed.orderedIDs.count - 1)
        let shown = try #require(feed.activePostID)

        feed.swipePushDidEnd(committed: false)
        #expect(sideList.isOpen, "a cancelled push closed the list")
        feed.swipePushDidEnd(committed: true)
        #expect(!sideList.isOpen)
        #expect(feed.activePostID == shown, "the post on show did not stay")
        #expect(feed.orderedIDs == [PostID("p1"), shown, PostID("p2")])
    }

    /// No router that makes a profile: no push stage at all.
    @Test func noDestinationNoPushStage() async throws {
        let feed = try await tests.openableFeedForChain(["t1"], text: ["t1"], router: nil)
        #expect(feed.swipeStage(for: .leftward, at: center(of: feed)) == nil)
    }
}

/// The side list's session in the view model (#1509): the feed set aside
/// while the list drives the card, restored untouched on close.
@MainActor
struct FeedViewModelSideListSessionTests {
    private func loaded(_ ids: [String]) async -> (FeedViewModel, () -> [String]) {
        let viewModel = FeedViewModel(repository: SideListProvider())
        var shown: [String] = []
        var renders = 0
        viewModel.onStateChange = { state in
            shown = state.items.map(\.id.rawValue)
            renders += 1
        }
        // The builder comes with the screen's load; the (empty) first page
        // lands before the seed.
        viewModel.viewDidLoad()
        for _ in 0..<6_000 where renders == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        viewModel.seed(ids.map {
            FeedItemDisplayModel(
                id: PostID($0), authorID: ProfileID("x"), authorName: "X", metaText: "", avatarURL: nil,
                caption: "", mediaURL: nil, mediaKind: .image, thumbnailURL: nil, audioText: nil
            )
        })
        return (viewModel, { shown })
    }

    @Test func theListReplacesTheFeedWhileOpen() async {
        let (viewModel, shown) = await loaded(["a", "b", "c"])
        let began = await viewModel.beginSideListSession(
            anchor: PostID("b"), entries: ["b", "x", "y"].map { SideListProvider.entry($0) }
        )
        #expect(began)
        #expect(viewModel.isInSideListSession)
        #expect(shown() == ["b", "x", "y"], "not the anchor then the list: \(shown())")
        #expect(await !viewModel.beginSideListSession(anchor: PostID("x"), entries: []), "a second session began")
    }

    /// Closed mid-list: the post on show right after the anchor.
    @Test func aMidListCloseKeepsThePostOnShowAfterTheAnchor() async {
        let (viewModel, shown) = await loaded(["a", "b", "c"])
        await viewModel.beginSideListSession(anchor: PostID("b"), entries: ["b", "x", "y"].map { SideListProvider.entry($0) })
        let index = viewModel.endSideListSession(anchor: PostID("b"), keeping: PostID("y"))
        #expect(shown() == ["a", "b", "y", "c"], "\(shown())")
        #expect(index == 2)
        #expect(!viewModel.isInSideListSession)
    }

    /// Past the list's end: the feed untouched, on the post after the anchor.
    @Test func anEndOfListCloseLandsAfterTheAnchor() async {
        let (viewModel, shown) = await loaded(["a", "b", "c"])
        await viewModel.beginSideListSession(anchor: PostID("b"), entries: ["b", "x"].map { SideListProvider.entry($0) })
        let index = viewModel.endSideListSession(anchor: PostID("b"), keeping: nil)
        #expect(shown() == ["a", "b", "c"], "the list leaked into the feed: \(shown())")
        #expect(index == 2, "not the post after the anchor")
    }

    /// Closed on the anchor: exactly the feed it was.
    @Test func aCloseOnTheAnchorRestoresTheFeed() async {
        let (viewModel, shown) = await loaded(["a", "b", "c"])
        await viewModel.beginSideListSession(anchor: PostID("b"), entries: ["b", "x"].map { SideListProvider.entry($0) })
        #expect(viewModel.endSideListSession(anchor: PostID("b"), keeping: PostID("b")) == 1)
        #expect(shown() == ["a", "b", "c"])
    }
}

/// A feed whose first page is `entries`, and the end.
private final class PostsProvider: FeedProviding, @unchecked Sendable {
    let entries: [FeedEntry]
    init(entries: [FeedEntry]) { self.entries = entries }
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { FeedPage(entries: entries, nextPageToken: nil, isCold: false) }
    func loadPage(afterToken token: String) async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        guard let entry = entries.first(where: { $0.post.id == id }) else { throw URLError(.fileDoesNotExist) }
        return entry
    }
}

private final class SideListReporter: ContentReporting, @unchecked Sendable {
    func report(_ subject: ReportSubject, reason: ReportReason, surface: String) async throws {}
}

private final class SideListProvider: FeedProviding, @unchecked Sendable {
    static func entry(_ id: String) -> FeedEntry {
        FeedEntry(
            post: Post(id: PostID(id), authorID: ProfileID("p"), caption: "", attachments: [], publishedAt: Date(timeIntervalSince1970: 0)),
            author: AuthorSummary(id: ProfileID("p"), handle: "ava", displayName: "Ava", avatarURL: nil),
            likeCount: 0
        )
    }

    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry { Self.entry(id.rawValue) }
}
