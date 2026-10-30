import CoreContracts
import CoreModels
import CoreNavigation
import Foundation
import MediaCore
import MediaPlayback
import PostGrid
import ShareSheet
import DesignSystem
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

        // The scaled page, cropped top and bottom by `pageInset`, IS the card.
        let page = Self.card(geometry)
        let inset = geometry.pageInset(progress: 1) * geometry.cardScale
        let card = page.insetBy(dx: 0, dy: inset)
        #expect(abs(card.minY - geometry.cardFrame.minY) < 0.01 && abs(card.height - geometry.cardFrame.height) < 0.01,
                "the crop does not make the card: \(card) \(geometry.cardFrame)")
        let list = geometry.listFrame(progress: 1)
        #expect(card.minY >= bars.top + gap - 0.01, "the card runs under the top bar: \(card)")
        #expect(card.maxY <= size.height - bars.bottom - gap + 0.01, "the card runs under the toolbar: \(card)")
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

    /// ⚠️ WHOLE 3:4 TILES, 10 ON AN 18 PRO (#1545, #1580): the tiles and
    /// their spacing fill the height between the bars exactly — none cut at
    /// rest; a shorter screen holds fewer, still whole.
    @Test(arguments: [0, 1])
    func theListHoldsWholeTiles(_ device: Int) {
        let (size, bars) = Self.devices[device]
        let geometry = SnapSideList.Geometry(size: size, bars: bars)
        let count = CGFloat(geometry.tileCount)
        let tile = geometry.tileSize
        let filled = count * tile.height + (count - 1) * SnapSideList.Geometry.tileSpacing
        #expect(abs(filled - geometry.listFrame(progress: 1).height) < 0.01, "the tiles do not fill the list: \(filled)")
        #expect(abs(tile.width - tile.height * 3 / 4) < 0.01, "the tiles are not 3:4")
        #expect(geometry.listWidth == tile.width)
        if device == 0 { #expect(geometry.tileCount == 10, "an 18 Pro holds \(geometry.tileCount)") }
        if device == 1 { #expect(geometry.tileCount < 10, "an SE holds as many as an 18 Pro") }
    }

    /// ⚠️ THE CARD IS WIDER (#1545): wider than the page fitted to the height
    /// between the bars was (#1509) — the 3:4 tiles leave it the most room.
    @Test func theCardIsWiderThanAPageFittedToTheHeight() {
        let (size, bars) = Self.devices[0]
        let geometry = SnapSideList.Geometry(size: size, bars: bars)
        let fittedWidth = size.width * geometry.openArea.height / size.height
        #expect(geometry.cardFrame.width > fittedWidth + 30, "\(geometry.cardFrame.width) vs \(fittedWidth)")
        #expect(geometry.pageInset(progress: 0) == 0, "closed, the page is cropped")
        #expect(geometry.pageInset(progress: 1) > 0, "the page overruns the bars and is not cropped")
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
        let band = Self.devices[0].bars.bottom
        #expect(geometry.overlayOffset(progress: 0) == 0)
        // ⚠️ THE OVERLAY'S FOOT KEEPS ITS SIDE MARGIN (#1549): open, the
        // lowest element (the band plus the strip's gap above the page's
        // bottom at rest) lands `overlayBottomMargin` above the card's foot —
        // the page's bottom less the crop.
        let foot = geometry.size.height - geometry.pageInset(progress: 1)
        let lowest = geometry.size.height - band - SnapChromeView.pageBarToolbarGap + geometry.overlayOffset(progress: 1)
        #expect(abs(foot - lowest - SnapSideList.Geometry.overlayBottomMargin) < 0.01, "the foot's gap: \(foot - lowest)")
        #expect(geometry.overlayOffset(progress: 0.5) < geometry.overlayOffset(progress: 1))
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

    /// A post of three pictures — a carousel.
    private static func carouselEntry(_ id: String) -> FeedEntry {
        FeedEntry(
            post: Post(
                id: PostID(id), authorID: ProfileID("author-\(id)"), caption: "caption \(id)",
                attachments: (0..<3).map { page in MediaAttachment(
                    url: URL(string: "https://cdn.example/\(id)-\(page).jpg"), thumbnailURL: nil,
                    mimeType: "image/jpeg", pixelWidth: 1080, pixelHeight: 1350
                ) },
                publishedAt: Date(timeIntervalSince1970: 1_760_000_000)
            ),
            author: AuthorSummary(id: ProfileID("author-\(id)"), handle: "h-\(id)", displayName: "Name \(id)", avatarURL: nil),
            likeCount: 0
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
                publishedAt: Date(timeIntervalSince1970: 1_760_000_000)
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

    /// The post share sheet's own chips (#1710, #1712): Repost, then the ⋯
    /// menu's Not interested and Report — Report only with somewhere to file.
    @Test func theShareSheetOffersRepostNotInterestedAndReport() {
        // Shots — the For You root — offers Repost; a pushed post does not
        // (its toolbar carries it, #1728).
        let feed = feed(sideList: false)
        feed.isForYouRoot = true
        #expect(feed.shareSheetActions(for: PostID("p1")).map(\.title) == ["Repost", "Not interested", "Report"])

        let unfiled = SnapFeedViewController(
            viewModel: FeedViewModel(repository: SideListProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        unfiled.isForYouRoot = true
        #expect(unfiled.shareSheetActions(for: PostID("p1")).map(\.title) == ["Repost", "Not interested"],
                "Report offered with nowhere to file it")
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
        // The card's crop and corners are its mask's (#1545).
        #expect((pager.mask?.layer.cornerRadius ?? 0) > 0, "the open card is square")
        #expect(pager.transform.a < 1 && pager.transform.a == pager.transform.d, "not one uniform scale")
        #expect(feed.view.transform == .identity, "the screen itself moved")
        #expect(!sideList.listView.isHidden)
        #expect(!feed.isReadyForInteractiveDismissal, "a dismissal could begin while the list is open")
        #expect(pager.allowsBackwardPaging, "the pager does not page back while open")

        // ⚠️ THE ACTION COLUMN LOWERS WITH THE REST (#1549): the like pill
        // and the sound bubble live outside the chrome, in the cell.
        for case let cell as SnapFeedCell in feed.collectionView.visibleCells {
            #expect(cell.debugChrome.debugActionColumnOffset == cell.sideListOverlayOffset,
                    "the like and the sound bubble stayed behind")
        }

        sideList.settle(open: false, animated: false)
        #expect(pager.transform == .identity)
        #expect(pager.mask == nil, "the page stayed cropped after the close")
        for case let cell as SnapFeedCell in feed.collectionView.visibleCells {
            #expect(cell.debugChrome.debugActionColumnOffset == 0, "the action column stayed down")
        }
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
                publishedAt: Date(timeIntervalSince1970: 1_760_000_000)
            ),
            author: AuthorSummary(id: ProfileID("author-\(id)"), handle: "h", displayName: "N", avatarURL: nil),
            likeCount: 812
        )
    }

    /// ⚠️ A TILE MADE BEFORE IT SHOWS GETS ITS RING WHEN IT SHOWS (the owner,
    /// 2026-10-22): the list prefetches, so a cell made while another post
    /// was on show — then ringed for the post the card paged onto, off screen
    /// — must take that ring as it comes into view. It came in bare.
    @Test func aTilePreparedOffScreenWearsItsRingWhenItShows() throws {
        let list = SnapSideListView(imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
        list.frame = CGRect(x: 0, y: 0, width: 80, height: 300)
        list.layoutIfNeeded()
        let entries = (0..<12).map { Self.clip("v\($0)") }
        list.show(entries)
        list.layoutIfNeeded()
        let collection = list.debugCollection
        let last = IndexPath(item: entries.count - 1, section: 0)
        // Made ahead, as a prefetch makes it: the ring is still the first post's.
        list.setRing([entries[0].post.id: 1], animated: false)
        let prepared = try #require(collection.dataSource?.collectionView(collection, cellForItemAt: last))
        #expect(prepared.contentView.layer.borderWidth == SnapSideListView.hairlineWidth)
        // The card pages onto the last post while its tile is off screen…
        list.setRing([entries[last.item].post.id: 1], animated: false)
        #expect(prepared.contentView.layer.borderWidth == SnapSideListView.hairlineWidth, "guard: off screen, not restyled")
        // …and it comes on screen ringed.
        collection.delegate?.collectionView?(collection, willDisplay: prepared, forItemAt: last)
        #expect(prepared.contentView.layer.borderWidth == SnapSideListView.ringWidth, "the tile came in without its ring")
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

    /// ⚠️ THE POST ON SHOW'S TILE IS A CLONE OF THE CARD (#1581, the owner
    /// 2026-10-22): no player, no loan of its own — a passive second surface
    /// on the card's player, so a pause, a scrub, the frame are the card's.
    /// Its own loan stays the other tiles'. Closed, the mirror comes off and
    /// the card's player plays on.
    @Test func thePostOnShowsTileMirrorsTheCardsPlayer() async throws {
        let pool = VideoPlaybackController(source: StubSource(), poolSize: 6)
        let list = SnapSideListView(imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
        let autoplay = SnapSideListAutoplay(pool: pool, imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
        list.autoplay = autoplay
        list.frame = CGRect(x: 0, y: 0, width: 80, height: 600)
        list.layoutIfNeeded()
        list.show((0..<6).map { Self.clip("v\($0)") })
        let cells = list.debugTileCells
        for _ in 0..<600 where !cells.allSatisfy({ $0.renderedCover != nil }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try #require(cells.allSatisfy { $0.renderedCover != nil }, "guard: the covers landed")
        var waited = 0
        while !GridVideoPlaybackCoordinator.allowsAutoplay(), waited < 400 {
            waited += 1
            try? await Task.sleep(for: .milliseconds(5))
        }

        // The card: a surface playing the same clip on its own player.
        let card = VideoRenderView()
        let url = try #require(URL(string: "mock://video/side-v3"))
        await pool.play(url, in: card, scope: "v3")
        try #require(pool.hasPlayer(in: card), "guard: the card plays")
        let loansBefore = pool.activePlayerCount
        let capBefore = pool.debugItem(in: card)?.preferredPeakBitRate
        autoplay.cardSurface = { $0 == PostID("v3") ? card : nil }
        autoplay.mirror(PostID("v3"))
        list.setPlaying(true)

        #expect(autoplay.playback.loanedCell(PostID("v3")) == nil, "the post on show's tile took a player of its own")
        #expect(autoplay.mirrorsCard, "the post on show's tile does not draw the card's player")
        #expect(pool.activePlayerCount >= loansBefore)
        #expect(pool.debugItem(in: card)?.preferredPeakBitRate == capBefore, "the mirror re-capped the card")
        // One player: the card paused, the mirror shows a stopped clip too.
        #expect(pool.setPaused(true, in: card))
        #expect(autoplay.mirrorPlayheadMatchesCard(card), "the tile is not the card's frame")

        // A recycled tile lets the card's player go, and never stops it.
        let mirrored = try #require(cells.first { cell in
            cell.loadedVideoRenderView.map { pool.sharesPlayback($0, with: card) && !pool.hasPlayer(in: $0) } ?? false
        })
        autoplay.stop(mirrored)
        #expect(!autoplay.mirrorsCard, "a recycled tile kept drawing the card")
        #expect(pool.hasPlayer(in: card), "a recycled mirror stopped the card's player")
        #expect(pool.debugItem(in: card)?.preferredPeakBitRate == capBefore)

        list.setPlaying(false)
        #expect(!autoplay.mirrorsCard, "the mirror outlived the list")
        #expect(pool.hasPlayer(in: card), "closing the list stopped the card's player")
    }

    /// ⚠️ THE POST ON SHOW FIRST, THEN SIMILAR POSTS (#1509): current posts
    /// of the feed's kind, none already in it, once each — and the same
    /// list again for the same anchor.
    @Test func theListIsThePostOnShowThenOthersOfTheFeedsKind() async throws {
        // A feed whose first page has LANDED: with a seed alone, the empty
        // first page could land between the seed and the ask and take the
        // post on show's kind with it (a 1-in-3 flake).
        let feed = try await openableFeed(["p1"], others: [])
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
        _ ids: [String], others: [String], text: Set<String> = [], carousels: Set<String> = [],
        router: (any Router)? = nil, comments: (any CommentsProviding)? = nil
    ) async throws -> SnapFeedViewController {
        let controller = SnapFeedViewController(
            // Its first page IS the feed: a seed alone is replaced by the
            // first page when it lands.
            viewModel: FeedViewModel(
                repository: PostsProvider(entries: ids.map {
                    carousels.contains($0) ? Self.carouselEntry($0) : Self.entry($0, media: !text.contains($0))
                }), commentsProvider: comments, router: router
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
        _ ids: [String], others: [String] = [], text: Set<String> = [], carousels: Set<String> = [],
        router: (any Router)?
    ) async throws -> SnapFeedViewController {
        let feed = try await openableFeed(ids, others: others, text: text, carousels: carousels, router: router)
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

    /// ⚠️ THE RING FOLLOWS THE CARD'S SCROLL (#1546): half way between two
    /// posts, their tiles share it half and half; back on the first, it is
    /// the first's alone.
    @Test func theRingCrossFadesWithTheCardsScroll() async throws {
        let feed = try await openableFeed(["p1", "p2"], others: ["m1", "m2"])
        let sideList = try await open(feed)
        let pager = try #require(feed.collectionView)
        sideList.listView.layoutIfNeeded()
        let page = pager.bounds.height
        pager.contentOffset.y = page / 2
        feed.scrollViewDidScroll(pager)
        let first = try #require(sideList.listView.debugRing(at: 0))
        let second = try #require(sideList.listView.debugRing(at: 1))
        #expect(abs(first.weight - 0.5) < 0.01 && abs(second.weight - 0.5) < 0.01, "not shared half way: \(first) \(second)")
        let half = SnapSideListView.hairlineWidth + (SnapSideListView.ringWidth - SnapSideListView.hairlineWidth) / 2
        #expect(abs(first.width - half) < 0.01, "the ring's width does not follow: \(first.width)")

        pager.contentOffset.y = 0
        feed.scrollViewDidScroll(pager)
        #expect(sideList.listView.debugRing(at: 0)?.weight == 1)
        #expect(sideList.listView.debugRing(at: 1)?.weight == 0, "a cancelled swipe left the ring shared")
    }

    /// ⚠️ A TILE'S TAP SHOWS ITS POST AT ONCE (#1548): no scroll through the
    /// posts in between — the pager is on it in the same turn — and the
    /// card's order is still the list's.
    @Test func aTilesTapShowsItsPostAtOnce() async throws {
        let feed = try await openableFeed(["p1", "p2"], others: ["m1", "m2", "m3", "m4"])
        let sideList = try await open(feed)
        let order = feed.orderedIDs
        let last = try #require(sideList.listView.entries.last)
        feed.showSideListEntry(last)
        #expect(feed.activePostID == last.post.id, "the card is not on the tapped post at once")
        #expect(!feed.collectionView.isDecelerating && feed.collectionView.layer.animationKeys() == nil,
                "the card scrolled to it")
        #expect(feed.orderedIDs == order, "the card's order changed")
    }

    /// ⚠️ WITH THE LIST OPEN, A TAP ON THE CARD CLOSES IT (#1550) — it
    /// takes the tap, so the clip is not toggled; closed, a tap is the
    /// page's again.
    @Test func withTheListOpenATapOnTheCardClosesIt() async throws {
        let feed = try await openableFeed(["p1", "p2"], others: ["m1", "m2"])
        let sideList = try await open(feed)
        let cell = try #require(feed.collectionView.visibleCells.compactMap { $0 as? SnapFeedCell }.first)
        #expect(cell.interceptsMediaTap?() == true, "the card's tap did not go to the list")
        #expect(sideList.isSettling || !sideList.isOpen, "the list did not close")
        sideList.settle(open: false, animated: false)
        #expect(cell.interceptsMediaTap?() == false, "a closed list still takes the card's taps")
    }

    /// The post on show's own tile toggles its clip in place (#1550): the
    /// card stays on it.
    @Test func thePostOnShowsTileDoesNotJump() async throws {
        let feed = try await openableFeed(["p1", "p2"], others: ["m1", "m2"])
        let sideList = try await open(feed)
        let shown = try #require(sideList.listView.entries.first)
        feed.showSideListEntry(shown)
        #expect(feed.activePostID == shown.post.id)
    }

    /// The stopped mark sits on the tile's centre, the card's component at
    /// the tile's size, and comes down on request (#1550).
    @Test func theTileWearsTheStoppedMark() async throws {
        let feed = try await openableFeed(["p1", "p2"], others: ["m1", "m2"])
        let sideList = try await open(feed)
        let list = sideList.listView
        list.layoutIfNeeded()
        let id = try #require(list.entries.first?.post.id)
        list.setPausedMark(true, on: id)
        #expect(list.debugShowsPausedMark(on: id), "no mark on the tile")
        list.setPausedMark(false, on: id)
        #expect(!list.debugShowsPausedMark(on: id), "the mark stayed")
    }

    /// ⚠️ THE MARK CROSSES WITH THE MOVE (#1580, the owner's recording): a
    /// paused clip's stopped mark is on the card at 1 − progress and on its
    /// tile at progress while the list moves, and the side the move ends on
    /// keeps it whole.
    @Test func aPausedClipsMarkCrossesWithTheMove() async throws {
        let feed = try await openableFeed(["p1", "p2"], others: ["m1", "m2"])
        let sideList = try await open(feed)
        let list = sideList.listView
        list.layoutIfNeeded()
        let id = try #require(feed.activePostID)
        let cell = try #require(feed.debugSettledSnapCell)
        // Paused from its tile, list open (#1550).
        feed.sideListPausedPost = id
        list.setPausedMark(true, on: id, animated: false)

        feed.sideListPoseDidChange(progress: 0.4)
        #expect(abs((cell.debugPausedMarkAlpha ?? -1) - 0.6) < 0.001, "the card's mark is not 1 − progress")
        #expect(abs(list.debugPausedMarkAlpha - 0.4) < 0.001, "the tile's mark is not progress")
        feed.sideListPoseDidChange(progress: 0.1)
        #expect(abs((cell.debugPausedMarkAlpha ?? -1) - 0.9) < 0.001)

        feed.sideListDidSettle(open: false)
        #expect(cell.debugPausedMarkAlpha == 1, "the card did not keep the mark whole")
        #expect(!list.debugShowsPausedMark(on: id), "the tile kept a mark after the close")
        #expect(feed.sideListPausedPost == nil)

        // And back: the card's mark crosses to the tile as the list opens.
        feed.sideListPoseDidChange(progress: 0.7)
        #expect(abs((cell.debugPausedMarkAlpha ?? -1) - 0.3) < 0.001)
        feed.sideListDidSettle(open: true)
        #expect(cell.debugPausedMarkAlpha == nil, "the card kept a mark with the list open")
        #expect(list.debugShowsPausedMark(on: id) && list.debugPausedMarkAlpha == 1)
        #expect(feed.sideListPausedPost == id)
    }

    /// A playing clip: the move carries no mark at all.
    @Test func aPlayingClipsMoveShowsNoMark() async throws {
        let feed = try await openableFeed(["p1", "p2"], others: ["m1", "m2"])
        let sideList = try await open(feed)
        let id = try #require(feed.activePostID)
        let cell = try #require(feed.debugSettledSnapCell)
        feed.sideListPoseDidChange(progress: 0.5)
        #expect(cell.debugPausedMarkAlpha == nil)
        #expect(!sideList.listView.debugShowsPausedMark(on: id))
    }

    /// ⚠️ THE LIST IS THE SOURCE'S (#1580, the owner's recording): closed on
    /// a post picked in it, the list reopens as it was — the source's list,
    /// the card on the picked post at its place in it — not a new list made
    /// for the picked post.
    @Test func reopenedOnAPickedPostTheListIsKept() async throws {
        let feed = try await openableFeed(["p1", "p2"], others: ["m1", "m2"])
        let sideList = try await open(feed)
        let list = sideList.listView.entries.map(\.post.id)
        let last = feed.orderedIDs.count - 1
        let picked = try #require(feed.orderedIDs.last)
        feed.settlePager(onIndex: last)
        sideList.settle(open: false, animated: false)
        #expect(feed.activePostID == picked)

        sideList.loadIfNeeded()
        sideList.settle(open: true, animated: false)
        try #require(await settle { feed.isSideListSessionActive }, "the list does not drive the card")
        #expect(sideList.listView.entries.map(\.post.id) == list, "a new list was made for the picked post")
        #expect(feed.orderedIDs == list, "the card does not page through the source's list")
        #expect(feed.activePostID == picked, "the card left the picked post")
        #expect(feed.orderedIDs.firstIndex(of: picked) == last, "the picked post is not at its place")
    }

    /// ⚠️ THE POST ON SHOW IS NEVER RE-ACTIVATED BY THE LIST (#1580, the
    /// owner's device check): opening or closing the list on a post that is
    /// not its source changes that post's index in the pager. Read by index,
    /// the screen sat for a moment on another post and re-activated the post
    /// on show — its clip or song jumped. No activation at all, either way.
    @Test func openingAndClosingNeverReactivateThePostOnShow() async throws {
        let feed = try await openableFeed(["p1", "p2"], others: ["m1", "m2"])
        // On screen: pages activate only then.
        feed.beginAppearanceTransition(true, animated: false)
        feed.endAppearanceTransition()
        let sideList = try await open(feed)
        let last = feed.orderedIDs.count - 1
        let picked = try #require(feed.orderedIDs.last)
        feed.settlePager(onIndex: last)
        #expect(feed.activePostID == picked)
        try #require(feed.debugActivations.last == picked, "guard: pages do not activate here")
        feed.debugActivations = []

        sideList.settle(open: false, animated: false)
        #expect(feed.activePostID == picked)
        sideList.loadIfNeeded()
        sideList.settle(open: true, animated: false)
        try #require(await settle { feed.isSideListSessionActive })
        #expect(feed.activePostID == picked)
        #expect(feed.debugActivations.isEmpty, "the list re-activated: \(feed.debugActivations.map(\.rawValue))")
    }

    /// ⚠️ THE BAND KEEPS CONVEYING THROUGH THE LIST (#1798, the owner's
    /// recording): opening and closing the side list cut the post on show's
    /// reaction band, held it dark a beat and faded a new train in. The list
    /// only scales the pager; nothing about the band changes, so nothing may
    /// lay its train again.
    @Test func openingAndClosingTheListNeverRelaysTheBand() async throws {
        // Reactions for the band, sentences for the pill.
        let bodies = (0..<10).map { "GG 🔥 \($0)" }
            + (0..<3).map { "This is a longer thought number \($0) worth reading." }
        let comments = bodies.enumerated().map { index, body in
            CommentEntry(
                id: "c\(index)", authorID: ProfileID("prof-1"), authorName: "Ava", authorHandle: "ava",
                body: body, createdAt: Date(timeIntervalSince1970: 1000)
            )
        }
        let feed = try await openableFeed(
            ["p1", "p2", "p3"], others: ["m1", "m2"], comments: SideListComments(entries: comments)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = feed
        window.makeKeyAndVisible()
        window.isHidden = false
        defer { window.isHidden = true }
        feed.beginAppearanceTransition(true, animated: false)
        feed.endAppearanceTransition()
        window.layoutIfNeeded()
        // Mid-feed, as on the device: opening moves the post on show to the
        // session's head and closing puts it back (#1580's reorder).
        feed.settlePager(onIndex: 1)
        try #require(await settle { feed.activePostID == PostID("p2") }, "guard: the second post on show")
        window.layoutIfNeeded()
        let band = try #require(feed.debugSettledSnapCell?.debugChrome.debugCommentTicker)
        let pill = try #require(feed.debugSettledSnapCell?.debugChrome.debugSubtitleView)
        try #require(await settle { band.debugIsConveying && pill.debugIsCycling },
                     "guard: the band conveys and the pill cycles before the list opens")
        let laid = band.debugTrainsLaid
        let cycle = pill.debugGeneration

        let sideList = try await open(feed)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        #expect(feed.debugSettledSnapCell?.debugChrome.debugCommentTicker === band, "guard: the post on show kept its cell")
        #expect(band.debugIsConveying, "opening the list stopped the band")
        #expect(band.debugTrainsLaid == laid, "opening the list laid the band's train again")
        #expect(pill.debugIsCycling && pill.debugGeneration == cycle, "opening the list restarted the pill")

        sideList.settle(open: false, animated: false)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        #expect(band.debugIsConveying, "closing the list stopped the band")
        #expect(band.debugTrainsLaid == laid, "closing the list laid the band's train again")
        #expect(pill.debugIsCycling && pill.debugGeneration == cycle, "closing the list restarted the pill")
    }

    /// ⚠️ DISMISSED, THE LIST CLOSES (#1580, the owner's recording): the
    /// screen is kept for the next post, and a list left open came back over
    /// it. Closed, its session ended, the kept list forgotten.
    @Test func aDismissalClosesTheList() async throws {
        let feed = try await openableFeed(["p1", "p2"], others: ["m1", "m2"])
        let sideList = try await open(feed)
        feed.settlePager(onIndex: 1)
        feed.closeSideListForDismissal()
        #expect(!sideList.isOpen && !sideList.isEngaged, "the list stayed open past the dismissal")
        #expect(!feed.isSideListSessionActive, "the card still pages through the list")
        #expect(feed.sideListResumeAnchor == nil, "the next post would reopen this list")
    }

    /// The feed taken up again after the close: the next opening is the post
    /// on show's own list.
    @Test func afterTheFeedMovesTheNextOpeningIsANewList() async throws {
        let feed = try await openableFeed(["p1", "p2"], others: ["m1", "m2"])
        let sideList = try await open(feed)
        feed.settlePager(onIndex: feed.orderedIDs.count - 1)
        sideList.settle(open: false, animated: false)
        #expect(feed.sideListResumeAnchor == PostID("p1"))
        // A settle alone (the close's own) keeps it; the viewer's drag ends it.
        let next = try #require(feed.orderedIDs.firstIndex(of: PostID("p2")))
        feed.settlePager(onIndex: next)
        feed.settlePager(onIndex: next - 1)
        #expect(feed.sideListResumeAnchor == PostID("p1"), "a settle ended the source's list")
        feed.scrollViewWillBeginDragging(feed.collectionView)
        #expect(feed.sideListResumeAnchor == nil, "the source's list outlived the feed taken up again")
    }

    /// ⚠️ A PULL PAST EITHER END OF THE LIST CLOSES IT (#1580): down on its
    /// first post, up on its last, only with the list open; on a middle post
    /// the pager keeps every drag.
    @Test func aPullPastEitherEndClosesTheList() async throws {
        let feed = try await openableFeed(["p1", "p2"], others: ["m1", "m2"])
        let sideList = try await open(feed)
        let last = feed.orderedIDs.count - 1
        try #require(last >= 2, "guard: a first, a middle and a last post")
        #expect(feed.sideListEdgePulls == .down, "the first post: \(feed.sideListEdgePulls)")
        feed.settlePager(onIndex: 1)
        #expect(feed.sideListEdgePulls.isEmpty, "a middle post closes the list on a pull")
        feed.settlePager(onIndex: last)
        #expect(feed.sideListEdgePulls == .up, "the last post: \(feed.sideListEdgePulls)")
        sideList.settle(open: false, animated: false)
        #expect(feed.sideListEdgePulls.isEmpty, "a closed list takes a pull")
    }

    /// Which drag is a closing pull: vertical first, then the way it goes.
    @Test func aClosingPullIsVerticalAndTowardItsEnd() {
        typealias Pull = SnapSideListEdgePull
        #expect(Pull.direction(of: CGPoint(x: 10, y: 300), allowed: .down) == .down)
        #expect(Pull.direction(of: CGPoint(x: 10, y: -300), allowed: .up) == .up)
        #expect(Pull.direction(of: CGPoint(x: 0, y: -300), allowed: .down) == nil, "a drag up on the first post")
        #expect(Pull.direction(of: CGPoint(x: 300, y: 100), allowed: [.down, .up]) == nil, "a sideways drag")
        #expect(Pull.direction(of: .zero, allowed: [.down, .up]) == nil)
    }

    /// A pull closes as the rightward swipe does, and the post on show
    /// stays full screen after it (#1509's mid-list rule, now at both ends).
    @Test func aPullCloseKeepsThePostOnShow() async throws {
        let feed = try await openableFeed(["p1", "p2"], others: ["m1", "m2"])
        let sideList = try await open(feed)
        let last = feed.orderedIDs.count - 1
        let picked = try #require(feed.orderedIDs.last)
        feed.settlePager(onIndex: last)
        sideList.settle(open: false, animated: false)
        #expect(!feed.isSideListSessionActive)
        #expect(feed.activePostID == picked, "the post on show did not stay full screen")
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

    /// The stage a drag would get, asked with no keyboard up.
    ///
    /// ⚠️ THE KEYBOARD'S STATE IS THE PROCESS'S (#1532's run): the feed
    /// tracks it from the global keyboard notifications, so a suite running
    /// beside this one that raises a text field's keyboard vetoed the chain
    /// here (`sideListMayOpen`) — a flake under load. Set and asked in one
    /// turn, nothing can land in between.
    private static func stage(_ feed: SnapFeedViewController, for direction: SwipeDirection, at point: CGPoint) -> SwipeStage? {
        feed.debugSetKeyboardOnScreen(false)
        return feed.swipeStage(for: direction, at: point)
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
        #expect(Self.isPanel(Self.stage(feed, for: .leftward, at: center(of: feed))))
        #expect(Self.stage(feed, for: .rightward, at: center(of: feed)) == nil)
    }

    /// ⚠️ A TEXT POST HAS NO LIST (#1525, the owner): leftward pushes the
    /// author's profile.
    @Test func aTextPostsLeftwardPushesTheAuthor() async throws {
        let router = ProfileRouter()
        let feed = try await tests.openableFeedForChain(["t1", "p2"], text: ["t1"], router: router)
        let stage = Self.stage(feed, for: .leftward, at: center(of: feed))
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
        let profile = try #require(Self.pushed(Self.stage(feed, for: .leftward, at: CGPoint(x: 60, y: feed.view.bounds.midY))))
        #expect(profile.title == "author-\(shown.rawValue)", "not the shown post's author")
        #expect(Self.isPanel(Self.stage(feed, for: .rightward, at: center(of: feed))), "rightward does not close the list")
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

    /// ⚠️ THE STACK'S BACK SWIPE WAITS FOR THE LIST (#1728): while the side
    /// list is open, a rightward drag closes it — the screen's full-surface
    /// back swipe is refused.
    @Test func theBackSwipeIsRefusedWhileTheListIsOpen() async throws {
        let feed = try await tests.openableFeedForChain(["p1", "p2"], others: ["o1", "o2"], router: ProfileRouter())
        #expect(feed.allowsContentPop(beginningAt: CGPoint(x: 200, y: 400), in: feed.view))
        _ = try await tests.openForChain(feed)
        #expect(!feed.allowsContentPop(beginningAt: CGPoint(x: 200, y: 400), in: feed.view), "the back swipe may close the post over the list")
    }

    /// ⚠️ A CAROUSEL'S EDGE OPENS THE LIST (#1720, the owner): from the
    /// trailing strip or the action column, a carousel opens the similar
    /// posts — any other post still pushes the author (the test below).
    @Test func aCarouselsEdgeAndColumnOpenTheList() async throws {
        let feed = try await tests.openableFeedForChain(["c1", "p2"], carousels: ["c1"], router: ProfileRouter())
        let edge = CGPoint(x: feed.view.bounds.maxX - 6, y: feed.view.bounds.midY)
        #expect(feed.isInTrailingEdge(edge))
        #expect(Self.isPanel(Self.stage(feed, for: .leftward, at: edge)), "a carousel's edge pushed the author")
        let shownChromes = feed.collectionView.visibleCells.compactMap { ($0 as? SnapFeedCell)?.debugChrome }
        let chrome = try #require(shownChromes.first, "guard: a page's chrome")
        let boost = chrome.debugBoostButton
        let column = boost.convert(CGPoint(x: boost.bounds.minX + 3, y: boost.bounds.midY), to: feed.view)
        #expect(feed.isOnTrailingColumn(column))
        #expect(Self.isPanel(Self.stage(feed, for: .leftward, at: column)), "a carousel's column pushed the author")
    }

    /// ⚠️ FROM THE RIGHT EDGE, THE PROFILE AT ONCE (#1592, the owner): a
    /// leftward drag born in the trailing strip pushes the author even on a
    /// media post with the list closed; one born mid-screen still opens the
    /// list.
    @Test func aLeftwardDragFromTheRightEdgePushesTheAuthor() async throws {
        let feed = try await tests.openableFeedForChain(["p1", "p2"], router: ProfileRouter())
        let edge = CGPoint(x: feed.view.bounds.maxX - PagedScreenDismissalPolicy.trailingEdgeZone + 4, y: feed.view.bounds.midY)
        let profile = try #require(Self.pushed(Self.stage(feed, for: .leftward, at: edge)), "the edge opened the list")
        #expect(profile.title == "author-p1")
        #expect(Self.isPanel(Self.stage(feed, for: .leftward, at: center(of: feed))), "mid-screen no longer opens the list")
    }

    /// ⚠️ THE TRAILING COLUMN IS THE EDGE (the owner, 2026-10-22): a leftward
    /// drag born on the like bubble's leading edge — inboard of the strip —
    /// pushes the author, as one born in the strip does.
    @Test func aLeftwardDragFromTheTrailingColumnPushesTheAuthor() async throws {
        let feed = try await tests.openableFeedForChain(["p1", "p2"], router: ProfileRouter())
        let shownChromes = feed.collectionView.visibleCells.compactMap { ($0 as? SnapFeedCell)?.debugChrome }
        let chrome = try #require(shownChromes.first, "guard: a page's chrome")
        let boost = chrome.debugBoostButton
        // Its leading edge: inboard of the strip, still on the column.
        let point = boost.convert(CGPoint(x: boost.bounds.minX + 3, y: boost.bounds.midY), to: feed.view)
        #expect(!feed.isInTrailingEdge(point), "guard: the bubble's leading edge is inboard of the strip")
        #expect(feed.isOnTrailingColumn(point))
        let profile = try #require(Self.pushed(Self.stage(feed, for: .leftward, at: point)), "the column opened the list")
        #expect(profile.title == "author-p1")
    }

    /// …and so is the save / share capsule between the like and the sound
    /// (#1710, the owner): a leftward drag born on it pushes the author — it
    /// opened the side list.
    @Test func aLeftwardDragFromTheCapsulePushesTheAuthor() async throws {
        let feed = try await tests.openableFeedForChain(["p1", "p2"], router: ProfileRouter())
        let shownChromes = feed.collectionView.visibleCells.compactMap { ($0 as? SnapFeedCell)?.debugChrome }
        let chrome = try #require(shownChromes.first, "guard: a page's chrome")
        chrome.setSoundFace(SnapSoundFace(coverURL: nil, isAvailable: true))
        chrome.showsPostActions = true
        chrome.layoutIfNeeded()
        let capsule = chrome.postActions
        let point = capsule.convert(CGPoint(x: capsule.bounds.midX, y: capsule.bounds.midY), to: feed.view)
        #expect(feed.isOnTrailingColumn(point), "the capsule is not the column")
        let profile = try #require(Self.pushed(Self.stage(feed, for: .leftward, at: point)), "the capsule opened the list")
        #expect(profile.title == "author-p1")
    }

    /// The emote rail never takes an edge drag: wherever it is, the edge
    /// strip — and the column itself — is tested first.
    @Test func theEdgeWinsOverTheRail() async throws {
        let feed = try await tests.openableFeedForChain(["p1", "p2"], router: ProfileRouter())
        let height = feed.view.bounds.height
        for y in stride(from: height * 0.2, through: height * 0.8, by: height * 0.1) {
            let edge = CGPoint(x: feed.view.bounds.maxX - 6, y: y)
            #expect(Self.pushed(Self.stage(feed, for: .leftward, at: edge)) != nil, "refused at y \(y)")
        }
    }

    /// No router that makes a profile: no push stage at all.
    @Test func noDestinationNoPushStage() async throws {
        let feed = try await tests.openableFeedForChain(["t1"], text: ["t1"], router: nil)
        #expect(Self.stage(feed, for: .leftward, at: center(of: feed)) == nil)
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

/// The same comments for every post: a band dense enough to convey.
private final class SideListComments: CommentsProviding, @unchecked Sendable {
    private let entries: [CommentEntry]
    init(entries: [CommentEntry]) { self.entries = entries }

    func loadComments(for postID: PostID) async throws -> [CommentEntry] { entries }

    func addComment(
        _ body: String, to postID: PostID, parentID: String?, commentID: String
    ) async throws -> CommentEntry {
        throw CommentsError.transport(message: "unused")
    }
}
