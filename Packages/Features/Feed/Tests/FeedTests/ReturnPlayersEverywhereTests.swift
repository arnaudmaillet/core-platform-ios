import CoreModels
import FeedInterface
import Foundation
import MediaCore
import MediaPlayback
import PostGrid
import Testing
import UIKit
@testable import Feed

/// #951: every surface that opens a post from a playing tile parks that tile's
/// clip for a close that pages on and comes home, and lands it back on the
/// tile — For You's list and rows (#923), and now the grids opened through
/// `ExternalHeroZoomSource`: the Discover gallery, the pushed lists, the search
/// and hashtag surface, the place page, and the sound sheet.
///
/// Two families here, as the code has them: the surfaces drawn by a
/// `ForYouGridPage`, and the sound sheet's own tiles. Each is pinned for the
/// parking (the tap parks the tile's clip), the landing choice (a close from
/// another post hands the tile its own clip, a same-post close is unchanged),
/// and the still fallback. The profile's gallery is pinned in its own package
/// (`ProfileReturnPlaybackTests`).
@MainActor
struct ReturnPlayersEverywhereTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private struct FixedVideoSource: VideoSource {
        let url: URL
        func playableURL(for url: URL) async throws -> URL { self.url }
    }

    private static func makePool() -> VideoPlaybackController {
        VideoPlaybackController(source: FixedVideoSource(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("return-everywhere.mp4")
        ))
    }

    private static func picture() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    /// Portrait clips, so a mosaic brick autoplays as well as a row.
    private static func videos(_ count: Int = 8, prefix: String = "v") -> [GalleryPost] {
        (0..<count).map { index in
            GalleryPost(
                id: PostID("\(prefix)\(index)"), kind: .video, isRepost: false,
                thumbnailURL: URL(string: "https://example.test/\(prefix)\(index).jpg"),
                videoURL: URL(string: "mock://video/\(prefix)\(index)"),
                aspectRatio: 0.75, caption: "clip \(index)", publishedAtMS: 0
            )
        }
    }

    /// The app-wide autoplay gate is another suite's to set
    /// (`FeedFeatureBuilder` points it at the playback policy); a tile can only
    /// be playing once it allows it.
    private static func whenAutoplayIsAllowed() async {
        for _ in 0..<1_000 where !GridVideoPlaybackCoordinator.allowsAutoplay() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private static func settle(_ condition: () -> Bool) async {
        await whenAutoplayIsAllowed()
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - The ForYouGridPage family (Discover gallery, pushed lists, search, place page)

    /// A page in a window whose first tile is PLAYING, as the one a finger
    /// taps is.
    private func playingPage(
        _ style: ForYouGridPage.Style, pool: VideoPlaybackController, prefix: String = "v"
    ) async throws -> (page: ForYouGridPage, tapped: PostID, window: UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let page = ForYouGridPage(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: style, videoPlayback: pool
        )
        page.frame = window.bounds
        window.addSubview(page)
        window.isHidden = false
        page.render(.content(Self.videos(prefix: prefix)))
        page.layoutIfNeeded()
        for post in page.posts {
            (page.debugCell(for: post.id) as? any GridPlaybackCell)?.applyCover(Self.picture())
        }
        await Self.whenAutoplayIsAllowed()
        page.setAutoplayActive(true)
        // The tile a finger would tap: one that is playing — which ones the
        // ranking chose is the page's business.
        func playing() -> PostID? {
            page.posts.first { post in
                guard let surface = (page.debugCell(for: post.id) as? any GridPlaybackCell)?
                    .loadedVideoRenderView else { return false }
                return pool.hasPlayer(in: surface)
            }?.id
        }
        // Reconciled again until it takes — see `whenAutoplayIsAllowed`.
        await Self.settle {
            page.updateAutoplay()
            return playing() != nil
        }
        let tapped = try #require(playing(), "precondition: a tile is playing")
        return (page, tapped, window)
    }

    /// The tap parks the tile's clip; the close resumes it on a surface of its
    /// own; the landing gives it to the tile, which then waits on its clip.
    @Test(arguments: [ForYouGridPage.Style.grid, .list])
    func aGridPageParksAndLandsTheTilesOwnClip(_ style: ForYouGridPage.Style) async throws {
        let pool = Self.makePool()
        let (page, tapped, window) = try await playingPage(style, pool: pool)
        defer { window.isHidden = true }

        page.beginPlaybackHandoff(of: tapped, parkingReturn: true)
        await Self.settle { pool.returnPlaybackCount == 1 }
        #expect(pool.returnPlaybackCount == 1, "the tap parked nothing")
        let active = pool.activePlayerCount

        let flying = try #require(page.returnFlightSurface(for: tapped))
        #expect(pool.activePlayerCount == active, "a resumed return player took a slot")
        #expect(page.landReturnPlayback(flying, for: tapped))
        #expect(pool.returnPlaybackCount == 0, "the landing did not claim the parked player")
        let tile = try #require((page.debugCell(for: tapped) as? any GridPlaybackCell)?.loadedVideoRenderView)
        #expect(pool.hasPlayer(in: tile))

        // ⚠️ `viewDidAppear` ends the scope in the landing's own turn (#963):
        // the hold, asked after it, still waits for the clip — the still is
        // up, and settling on it let the card go before the clip drew.
        page.endPlaybackHandoff()
        #expect(pool.hasPlayer(in: tile), "the scope's end took the landed clip away")
        #expect(!page.isReturnLandingReady(for: tapped), "the hold settled on the still")
    }

    // MARK: - The card window (#1294)

    /// ⚠️ A CLOSE THROUGH THE CARD WINDOW PLAYS THE TILE HOME (#1294). Paged
    /// onto a text post, the close has no picture to fly and goes through the
    /// window, whose stand-in used to be a still while the tile's clip sat
    /// parked for this very close. The stand-in now plays it, and the landing
    /// (the reveal showing the row again, a committed close only) hands it to
    /// the tile.
    @Test func theCardWindowPlaysTheTilesParkedClipAndTheTileTakesIt() async throws {
        let pool = Self.makePool()
        let (page, tapped, window) = try await playingPage(.grid, pool: pool)
        defer { window.isHidden = true }
        page.beginPlaybackHandoff(of: tapped, parkingReturn: true)
        await Self.settle { pool.returnPlaybackCount == 1 }

        let standIn = try #require(page.makeWindowStandIn(for: tapped))
        let clip = try #require(Self.firstVideoSurface(in: standIn), "the window carried a still")
        #expect(page.windowClips.debugHasClip(for: tapped))

        page.setRevealConcealed(true, for: tapped)
        page.setRevealConcealed(false, for: tapped)
        #expect(!page.windowClips.debugHasClip(for: tapped), "the landing kept the clip")
        // The clip stays over the tile until the tile draws it — no frame
        // where the stand-in has gone and the tile has not drawn yet.
        #expect(page.windowClips.debugIsHolding(tapped), "the landing let the clip go before the tile drew")
        await Self.settle { !page.windowClips.debugIsHolding(tapped) }
        #expect(!page.windowClips.debugIsHolding(tapped), "the hold never ended")
        #expect(pool.returnPlaybackCount == 0, "the landing did not claim the parked player")
        let tile = try #require((page.debugCell(for: tapped) as? any GridPlaybackCell)?.loadedVideoRenderView)
        #expect(pool.hasPlayer(in: tile), "the tile did not take the window's clip")
        _ = clip
    }

    /// A window close that springs back pauses the clip it was playing and
    /// lands nothing: the post stays open, and the clip waits for the next
    /// close.
    @Test func aCardWindowThatSpringsBackPausesTheClip() async throws {
        let pool = Self.makePool()
        let (page, tapped, window) = try await playingPage(.grid, pool: pool)
        defer { window.isHidden = true }
        page.beginPlaybackHandoff(of: tapped, parkingReturn: true)
        await Self.settle { pool.returnPlaybackCount == 1 }

        _ = try #require(page.makeWindowStandIn(for: tapped))
        page.windowCloseDidEnd(false, for: tapped)
        #expect(!page.windowClips.debugHasClip(for: tapped))
        #expect(pool.returnPlaybackCount == 1, "the spring-back released the parked clip")
    }

    /// A shelf's media card does the same through its own window
    /// (`PostShelfOrigins.cardReveal`).
    @Test func aShelfCardsWindowPlaysItsParkedClip() async throws {
        let pool = Self.makePool()
        let posts = Self.videos(4, prefix: "s")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let shelf = PostShelfSection(imagePipeline: ImagePipeline(fetcher: SilentFetcher()), videoPlayback: pool)
        shelf.frame = CGRect(x: 0, y: 100, width: 402, height: 400)
        window.addSubview(shelf)
        window.isHidden = false
        defer { window.isHidden = true }
        shelf.render(posts)
        shelf.visibleBand = { [weak shelf] in shelf?.bounds }
        shelf.layoutIfNeeded()
        for index in posts.indices { shelf.debugCardCell(at: index)?.applyCover(Self.picture()) }
        await Self.whenAutoplayIsAllowed()
        shelf.setAutoplayActive(true)
        await Self.settle {
            shelf.updateAutoplay()
            return shelf.debugCardCell(at: 0)?.loadedVideoRenderView.map { pool.hasPlayer(in: $0) } == true
        }
        let id = posts[0].id
        shelf.beginPlaybackHandoff(of: id)
        await Self.settle { pool.returnPlaybackCount == 1 }
        let page = ForYouGridPage(imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .discover)
        let reveal = PostShelfOrigins.cardReveal(for: posts[0], cover: Self.picture(), shelf: shelf, page: page)
        let standIn = try #require(reveal.makeDismissStandIn(nil))
        #expect(Self.firstVideoSurface(in: standIn) != nil, "the card's window carried a still")
        reveal.setConcealed(true)
        reveal.setConcealed(false)
        #expect(pool.returnPlaybackCount == 0, "the card did not take its window's clip")
        reveal.dismissalDidEnd(true)
    }

    private static func firstVideoSurface(in view: UIView) -> VideoRenderView? {
        if let surface = view as? VideoRenderView { return surface }
        for sub in view.subviews {
            if let found = firstVideoSurface(in: sub) { return found }
        }
        return nil
    }

    /// Nothing parked (evicted, or never playing): no surface, nothing landed,
    /// and the hold waits on the tile's still alone.
    @Test func aGridPageWithNothingParkedFallsBackToTheStill() async throws {
        let pool = Self.makePool()
        let (page, tapped, window) = try await playingPage(.grid, pool: pool)
        defer { window.isHidden = true }
        page.beginPlaybackHandoff(of: tapped, parkingReturn: true)
        await Self.settle { pool.returnPlaybackCount == 1 }
        pool.releaseAllReturnPlaybacks()

        #expect(page.returnFlightSurface(for: tapped) == nil)
        #expect(page.isReturnLandingReady(for: tapped), "the still is up; nothing else to wait for")
    }

    /// Each opener in the family hands the shared flight the return path, and
    /// parks when it opens.
    @Test func theDiscoverGalleryWiresTheReturn() async throws {
        let pool = Self.makePool()
        var opened: SnapFeedHeroOrigin?
        let gallery = DiscoverGalleryViewController(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            videoPlayback: pool,
            header: PushedScreenHeader(wallet: nil, makeWalletSheet: nil, router: nil),
            openPost: { _, origin, _ in opened = origin }
        )
        gallery.loadViewIfNeeded()
        gallery.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        gallery.render(.content(Self.videos(30)))
        gallery.view.layoutIfNeeded()
        #expect(gallery.debugOpenTile(at: 0))
        try Self.expectReturnWired(opened)
    }

    @Test func aPushedListWiresTheReturn() throws {
        var opened: SnapFeedHeroOrigin?
        let list = ForYouPostListViewController(
            kind: .following,
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            videoPlayback: Self.makePool(),
            staking: nil,
            header: PushedScreenHeader(wallet: nil, makeWalletSheet: nil, router: nil),
            openPost: { _, origin, _ in opened = origin }
        )
        let navigation = UINavigationController(rootViewController: list)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        list.render(.content(Self.videos(12)), newPosts: [])
        window.layoutIfNeeded()
        #expect(list.debugOpenRow(at: 0))
        try Self.expectReturnWired(opened)
    }

    @Test func theSearchAndHashtagSurfaceWiresTheReturn() async throws {
        let posts = Self.videos(8)
        let byID = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
        let surface = PostSetSurfaceViewController(
            style: .discover,
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            videoPlayback: Self.makePool(),
            hydrate: { ids in ids.compactMap { byID[$0] } }
        )
        var opened: SnapFeedHeroOrigin?
        surface.openPost = { _, origin, _ in opened = origin }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: surface)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        surface.show(.posts(posts.map(\.id)))
        await Self.settle {
            window.layoutIfNeeded()
            return surface.debugOpenTile(at: 0) && opened != nil
        }
        try Self.expectReturnWired(opened)
    }

    @Test func thePlacePageWiresTheReturn() async throws {
        let posts = Self.videos(12)
        var opened: SnapFeedHeroOrigin?
        let place = PlaceProfileViewController(
            postIDs: posts.map(\.id),
            placeName: "Paris • City Cluster",
            rank: nil,
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            videoPlayback: Self.makePool(),
            following: nil,
            wallet: nil,
            loadPosts: { posts },
            openPost: { _, origin, _ in opened = origin }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: place)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        // The builder starts the hydration at creation, not on appearance.
        place.beginLoading()
        await Self.settle {
            window.layoutIfNeeded()
            return place.debugOpenTile(at: 0) && opened != nil
        }
        try Self.expectReturnWired(opened)
    }

    // MARK: - A shelf's cards, on every host (#1271)

    /// ⚠️ A SHELF'S CARD IS A TILE UNDER #1269'S CONTRACT, on every screen
    /// that hosts one: it takes off playing, a same-post close continues its
    /// playhead, a close from another post comes home to its own parked clip,
    /// and the words fade in over it at rest. The origin is built by the
    /// SHELF (`PostShelfSection.openCard`), so a host can no longer forget a
    /// hook.
    private static func expectShelfTileContract(_ origin: SnapFeedHeroOrigin?) throws {
        let origin = try #require(origin, "the shelf's tap never reached the shared flight")
        #expect(origin.donateLiveMedia != nil, "the card does not take off playing")
        #expect(origin.adoptLandingLiveMedia != nil, "a same-post close restarts the clip")
        #expect(origin.landingMediaIsReady != nil)
        #expect(origin.returnLiveMedia != nil, "a close from another post lands on a still")
        #expect(origin.pauseReturnLiveMedia != nil)
        #expect(origin.restingOverlay != nil, "the words do not fade in over the card")
        #expect(origin.textReveal != nil, "no window for a close from a text page")
    }

    @Test func forYousFollowingCardsKeepTheTileContract() async throws {
        let posts = Self.videos(4, prefix: "f")
        var opened: SnapFeedHeroOrigin?
        let screen = ForYouViewController(
            viewModel: ForYouViewModel(repository: EmptyForYouProvider()),
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            videoPlayback: Self.makePool(),
            makeSnapFeed: { _ in UIViewController() },
            openPostHero: { _, origin, _ in opened = origin },
            prewarm: { _ in }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var rows = ForYouViewModel.Rails()
        rows.following = posts
        await Self.settle {
            // Re-asserted each turn: the view model's own first load renders
            // the (empty) rails after the screen appears.
            if screen.debugShelf.cards != posts { screen.debugShelf.render(posts) }
            window.layoutIfNeeded()
            screen.openCard(at: 0)
            return opened != nil
        }
        try Self.expectShelfTileContract(opened)
        #expect(opened?.post.id == posts[0].id)
    }

    @Test func thePlacePagesPopularCardsKeepTheTileContract() async throws {
        let posts = Self.videos(12, prefix: "p")
        var opened: SnapFeedHeroOrigin?
        let place = PlaceProfileViewController(
            postIDs: posts.map(\.id),
            placeName: "Paris • City Cluster",
            rank: nil,
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            videoPlayback: Self.makePool(),
            following: nil,
            wallet: nil,
            loadPosts: { posts },
            openPost: { _, origin, _ in opened = origin }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: place)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        place.beginLoading()
        await Self.settle {
            window.layoutIfNeeded()
            return place.debugOpenPopularCard(at: 0) && opened != nil
        }
        try Self.expectShelfTileContract(opened)
    }

    private static func expectReturnWired(_ origin: SnapFeedHeroOrigin?) throws {
        let origin = try #require(origin, "the tap never reached the shared flight")
        #expect(origin.returnLiveMedia != nil)
        #expect(origin.pauseReturnLiveMedia != nil)
        #expect(origin.adoptReturnLiveMedia != nil)
        #expect(origin.returnLandingIsReady != nil)
        // ⚠️ AND A SAME-POST CLOSE CONTINUES THE PLAYHEAD (#1270, epic
        // #1269): the tile takes the surface the card flew, as For You's own
        // tiles do — these used to restart the clip.
        #expect(origin.adoptLandingLiveMedia != nil)
        #expect(origin.landingMediaIsReady != nil)
    }

    // MARK: - The landing choice through the shared flight

    /// A close from another post through an origin wired like the family's:
    /// the tile takes its own clip through `adoptReturnLiveMedia`, at the
    /// reveal, and the hold asks the return gate. A same-post close goes
    /// through neither.
    @Test func aCloseFromAnotherPostUsesTheReturnPathAndASamePostCloseDoesNot() throws {
        var returned: [UIView] = []
        var landed: [UIView] = []
        var returnGateAsked = 0
        let surface = VideoRenderView()
        func origin() -> SnapFeedHeroOrigin {
            SnapFeedHeroOrigin(
                post: Self.videos(1)[0], cover: Self.picture(), style: .tile,
                frame: { _ in .zero }, isOnScreen: { true }, setConcealed: { _ in },
                adoptLandingLiveMedia: { landed.append($0) },
                returnLiveMedia: { surface },
                pauseReturnLiveMedia: {},
                adoptReturnLiveMedia: { returned.append($0) },
                returnLandingIsReady: { returnGateAsked += 1; return true }
            )
        }
        let other = ExternalHeroZoomSource(origin: origin(), settle: { (id: PostID("elsewhere"), cover: nil, page: nil) })
        other.zoomSourceWillStageDismissal()
        _ = other.makeZoomFlightCard()
        other.zoomAdoptLiveMediaView(VideoRenderView())
        #expect(returned.isEmpty, "the tile took its clip while still concealed")
        other.setZoomSourceHidden(false)
        #expect(returned.count == 1 && returned.first === surface)
        #expect(landed.isEmpty, "the page's playback was handed to the tile")
        _ = other.zoomLandingMediaIsReady
        #expect(returnGateAsked == 1)

        let same = ExternalHeroZoomSource(origin: origin(), settle: { (id: PostID("v0"), cover: nil, page: nil) })
        same.zoomSourceWillStageDismissal()
        _ = same.makeZoomFlightCard()
        let departure = VideoRenderView()
        same.zoomAdoptLiveMediaView(departure)
        same.setZoomSourceHidden(false)
        #expect(returned.count == 1, "a same-post close took the return path")
        #expect(landed.count == 1 && landed.first === departure)
        _ = same.zoomLandingMediaIsReady
        #expect(returnGateAsked == 1)
    }

    // MARK: - The sound sheet

    /// The sheet's tiles: the tap parks the tile's clip and stops the tile's
    /// own player (its flight carries the poster, so nothing else would), the
    /// landing hands the clip back, and the scope's end keeps it.
    @Test func theSoundSheetParksStopsAndLandsTheTilesOwnClip() async throws {
        let pool = Self.makePool()
        let autoplay = SoundSheetAutoplay(pool: pool, imagePipeline: ImagePipeline(fetcher: SilentFetcher()))
        autoplay.setActive(true)
        let cell = SoundSheetTileCell(frame: CGRect(x: 0, y: 0, width: 120, height: 160))
        let id = PostID("s0")
        let tile = cell.makeVideoRenderViewIfNeeded()
        // Asked again until it takes: the app-wide autoplay gate is other
        // suites' to flip, and a reconcile is idempotent.
        await Self.settle {
            autoplay.playback.update(candidates: [.init(
                id: id, url: URL(string: "mock://video/s0")!, cell: cell, distanceFromCentre: 0
            )])
            return pool.hasPlayer(in: tile)
        }
        #expect(pool.hasPlayer(in: tile), "precondition: the tile is playing")

        autoplay.beginOpen(of: id)
        // ⚠️ The flight carries the tapped tile's player now (#1280, epic
        // #1269): it takes off playing, as For You's tiles do.
        #expect(pool.hasPlayer(in: tile), "the tapped tile's player was stopped before the flight took it")
        await Self.settle { pool.returnPlaybackCount == 1 }
        #expect(pool.returnPlaybackCount == 1)
        autoplay.setActive(false)

        let flying = try #require(autoplay.playback.makeReturnSurface(for: id))
        #expect(autoplay.playback.landReturnPlayback(flying, for: id, cell: cell))
        #expect(pool.returnPlaybackCount == 0)

        autoplay.setActive(true)
        autoplay.endOpen()
        #expect(pool.hasPlayer(in: cell.loadedVideoRenderView ?? tile))
    }

    /// A screen left behind (not the viewer's when the feed closes) ends the
    /// scope and plays nothing.
    @Test func aSoundSheetScreenLeftBehindEndsTheScopeAndPlaysNothing() async throws {
        let pool = Self.makePool()
        let autoplay = SoundSheetAutoplay(pool: pool, imagePipeline: ImagePipeline(fetcher: SilentFetcher()))
        autoplay.setActive(true)
        let cell = SoundSheetTileCell(frame: CGRect(x: 0, y: 0, width: 120, height: 160))
        let id = PostID("s0")
        await Self.settle {
            autoplay.playback.update(candidates: [.init(
                id: id, url: URL(string: "mock://video/s0")!, cell: cell, distanceFromCentre: 0
            )])
            return pool.activePlayerCount == 1
        }
        autoplay.beginOpen(of: id)
        await Self.settle { pool.returnPlaybackCount == 1 }
        autoplay.setActive(false)

        autoplay.endOpen()
        #expect(!autoplay.playback.isHandingOff)
        #expect(pool.returnPlaybackCount == 0, "an unused return player outlived the trip")
        #expect(!autoplay.playback.debugIsSurfaceVisible, "a covered screen went back to playing")
    }

    // MARK: - The bound, across surfaces

    /// ⚠️ STACKED PUSHES ACROSS SURFACES. A list post opened into a sound
    /// sheet whose tile opens another post, opened in turn from a place page's
    /// grid: three surfaces, three parks, one pool. The two most recent fly
    /// their clip, the oldest lands on its still, and a fresh grid still gets
    /// its whole budget.
    @Test func stackedPushesAcrossSurfacesNeverStarveThePlaybackPool() async throws {
        let pool = Self.makePool()
        let (list, listTapped, listWindow) = try await playingPage(.list, pool: pool, prefix: "list")
        defer { listWindow.isHidden = true }
        list.beginPlaybackHandoff(of: listTapped, parkingReturn: true)
        await Self.settle { pool.returnPlaybackCount == 1 }

        let sheet = SoundSheetAutoplay(pool: pool, imagePipeline: ImagePipeline(fetcher: SilentFetcher()))
        sheet.setActive(true)
        let sheetCell = SoundSheetTileCell(frame: CGRect(x: 0, y: 0, width: 120, height: 160))
        let sheetID = PostID("sheet-tile")
        await Self.settle {
            sheet.playback.update(candidates: [.init(
                id: sheetID, url: URL(string: "mock://video/sheet")!, cell: sheetCell, distanceFromCentre: 0
            )])
            return pool.hasPlayer(in: sheetCell.makeVideoRenderViewIfNeeded())
        }
        sheet.beginOpen(of: sheetID)
        await Self.settle { pool.returnPlaybackCount == 2 }

        let (grid, gridTapped, gridWindow) = try await playingPage(.grid, pool: pool, prefix: "grid")
        defer { gridWindow.isHidden = true }
        grid.beginPlaybackHandoff(of: gridTapped, parkingReturn: true)
        await Self.settle { grid.hasReturnPlayback(for: gridTapped) }
        #expect(grid.hasReturnPlayback(for: gridTapped))
        #expect(!list.hasReturnPlayback(for: listTapped), "the oldest was not the one evicted")

        #expect(pool.returnPlaybackCount == VideoPlaybackController.returnPlaybackCapacity)
        #expect(list.returnFlightSurface(for: listTapped) == nil, "the oldest was not the one evicted")
        #expect(list.isReturnLandingReady(for: listTapped), "an evicted return waited for a clip")
        #expect(sheet.playback.makeReturnSurface(for: sheetID) != nil)
        #expect(grid.returnFlightSurface(for: gridTapped) != nil)

        let fresh = GridVideoPlaybackCoordinator(pool: pool, maxConcurrent: 3)
        fresh.setSurfaceVisible(true)
        let cells = (0..<3).map { _ in PostGridTileCell(frame: CGRect(x: 0, y: 0, width: 120, height: 160)) }
        let candidates = cells.enumerated().map { index, cell in
            GridVideoPlaybackCoordinator.Candidate(
                id: PostID("fresh\(index)"), url: URL(string: "mock://video/fresh\(index)")!,
                cell: cell, distanceFromCentre: CGFloat(index)
            )
        }
        await Self.settle {
            fresh.update(candidates: candidates)
            return cells.allSatisfy { pool.hasPlayer(in: $0.makeVideoRenderViewIfNeeded()) }
        }
        #expect(cells.allSatisfy { pool.hasPlayer(in: $0.makeVideoRenderViewIfNeeded()) },
                "a parked return player took a slot from a fresh grid")
    }
}
