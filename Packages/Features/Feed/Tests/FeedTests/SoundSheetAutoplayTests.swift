import CoreModels
import CoreStorage
import FeedInterface
import Foundation
import MediaCore
import MediaPlayback
import PostGrid
import Testing
import UIKit
@testable import Feed

/// The sound sheet's video tiles play on their own, muted, as every grid's do
/// (#884): the shared ranking (`GridAutoplayRanking`) and coordinator, the
/// mosaic's budget less what the page behind already holds, nothing faint and
/// nothing that is not a clip — and every player given back when the sheet
/// goes, a section is pushed over it, or a feed opened from a tile covers it.
///
/// ⚠️ `GridVideoPlaybackCoordinator.allowsAutoplay` follows the app's playback
/// policy, which a few suites set for a moment while they run beside this
/// one. A start is asked synchronously only once it reads "allowed"
/// (`whenAutoplayIsAllowed`), with no `await` before the assertion.
@MainActor
struct SoundSheetAutoplayTests {
    private typealias Sheet = SoundSheetViewController

    private struct StubSource: VideoSource {
        func playableURL(for url: URL) async throws -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("stub.mp4")
        }
    }

    private func makePool() -> VideoPlaybackController {
        VideoPlaybackController(source: StubSource(), poolSize: 6)
    }

    private static func clip(_ index: Int) -> URL { URL(string: "mock://video/sound-\(index)")! }

    /// `count` posts in "Recent" alone, newest first (p{count-1} … p0), each
    /// a clip unless `isClip` says otherwise.
    private func sheet(
        count: Int, isClip: (Int) -> Bool = { _ in true }, pool: VideoPlaybackController?
    ) -> Sheet {
        let ids = (0..<count).map { PostID("p\($0)") }
        let dealt = SoundSheetSections.make(
            rankings: PostSoundRankings(popular: [], recent: ids.reversed()),
            current: PostID("p0"), original: nil, isMedia: { _ in true }
        )
        let tiles = (0..<count).map { index in
            Sheet.Tile(
                postID: PostID("p\(index)"), thumbnailURL: nil, caption: nil, isCurrent: index == 0,
                videoURL: isClip(index) ? Self.clip(index) : nil
            )
        }
        return Sheet(
            sound: PostSound(id: "clip-01", title: "Veridis Quo", artist: nil, previewURL: nil, artworkURL: nil, duration: 30),
            authorHandle: "ava",
            fallbackArtworkURL: nil,
            sections: dealt.sections,
            tiles: tiles,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            savedSounds: SavedSoundStore(defaults: UserDefaults(suiteName: "SoundSheetAutoplay.\(UUID().uuidString)")!),
            videoPlayback: pool
        )
    }

    /// Laid out at a phone's size WITHOUT a window (see `SoundSheetTests
    /// .laidOut`): every cell the grid shows is realised.
    @discardableResult
    private func laidOut(_ controller: Sheet) throws -> UINavigationController {
        let navigation = controller.wrappedInSheet()
        navigation.loadViewIfNeeded()
        controller.loadViewIfNeeded()
        let width = try #require(controller.detentMetrics?.width)
        navigation.view.frame = CGRect(x: 0, y: 0, width: width, height: 874)
        navigation.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        try grid(of: controller).layoutIfNeeded()
        return navigation
    }

    private func grid(of controller: Sheet) throws -> UICollectionView {
        try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
    }

    private func tileCells(of controller: Sheet) throws -> [SoundSheetTileCell] {
        try grid(of: controller).visibleCells.compactMap { $0 as? SoundSheetTileCell }
    }

    /// The tiles the coordinator started: a start builds the tile's surface
    /// in the same turn (the player lands later), and nothing else builds one.
    private func startedCells(_ cells: [SoundSheetTileCell]) -> [SoundSheetTileCell] {
        cells.filter { $0.loadedVideoRenderView != nil }
    }

    private func whenAutoplayIsAllowed() async {
        var waited = 0
        while !GridVideoPlaybackCoordinator.allowsAutoplay(), waited < 400 {
            waited += 1
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<600 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// Up to the expanded detent, as the grabber would take it: appearing
    /// there, the reveal is whole and every tile on screen can be touched.
    private func expand(_ controller: Sheet) {
        controller.debugExpand()
        #expect(controller.isExpanded, "guard: expanded")
    }

    private func appear(_ controller: UIViewController) {
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
    }

    private func disappear(_ controller: UIViewController) {
        controller.beginAppearanceTransition(false, animated: false)
        controller.endAppearanceTransition()
    }

    // MARK: - What plays

    /// The regression: the sheet's tiles had no player at all. On appearing,
    /// the video tiles that can be touched play — under a collapsed reveal,
    /// "Recent"'s first row only, the rows after it faint — and never a tile
    /// without a clip.
    @Test func theFirstRowsClipsPlayAndNothingFaintOrStill() async throws {
        // p16, the first row's second tile, is a photograph.
        let controller = sheet(count: 18, isClip: { $0 != 16 }, pool: makePool())
        try laidOut(controller)
        let cells = try tileCells(of: controller)
        #expect(cells.count >= 9, "guard: three rows on screen")

        await whenAutoplayIsAllowed()
        appear(controller)
        let started = Set(startedCells(cells).compactMap(\.shownPostID))
        #expect(started == [PostID("p17"), PostID("p15")], "the first row's two clips, nothing faint")
    }

    /// Once the reveal is whole, the six nearest the middle play: the
    /// mosaic's budget (`GridAutoplayRanking.mosaicPlayers`), on a pool the
    /// page behind is not using.
    @Test func videoTilesPlayWithinTheMosaicsBudget() async throws {
        let controller = sheet(count: 18, pool: makePool())
        try laidOut(controller)
        expand(controller)
        let cells = try tileCells(of: controller)
        #expect(cells.count > GridAutoplayRanking.mosaicPlayers, "guard: more clips than the budget")

        await whenAutoplayIsAllowed()
        appear(controller)
        #expect(startedCells(cells).count == GridAutoplayRanking.mosaicPlayers)
    }

    /// ⚠️ THE PAGE BEHIND KEEPS ITS PLAYERS: the sheet rises over a feed that
    /// goes on playing on the same pool, and the tiles take what the pool's
    /// capacity leaves after it.
    @Test func theTilesLeaveThePageBehindItsPlayers() async throws {
        let pool = makePool()
        let behind = [VideoRenderView(), VideoRenderView()]
        for (index, surface) in behind.enumerated() {
            await pool.play(URL(string: "mock://video/behind-\(index)")!, in: surface, scope: "behind-\(index)")
        }
        #expect(pool.activePlayerCount == 2, "guard: the page behind holds two")
        let controller = sheet(count: 18, pool: pool)
        try laidOut(controller)
        expand(controller)

        await whenAutoplayIsAllowed()
        appear(controller)
        #expect(startedCells(try tileCells(of: controller)).count == pool.capacity - 2)
    }

    // MARK: - No leak

    /// Waits until `count` players are bound, reconciling at every look: a
    /// reconcile the app-wide gate turned down meanwhile stops the tiles (see
    /// the type's note), and the next one it allows starts them again.
    private func bound(_ count: Int, on pool: VideoPlaybackController, reconciling: () -> Void) async -> Bool {
        await settle {
            reconciling()
            return pool.activePlayerCount == count
        }
    }

    /// The players still bound a while later — a start's task landing after
    /// its stop is the leak this watches for, and it lands only once the
    /// source resolves.
    private func boundAfterAWhile(_ pool: VideoPlaybackController) async -> Int {
        for _ in 0..<100 {
            try? await Task.sleep(for: .milliseconds(5))
            if pool.activePlayerCount > 0 { break }
        }
        return pool.activePlayerCount
    }

    /// The sheet going — or a section pushed over it: the same
    /// `viewWillDisappear` — gives every tile's player back to the pool.
    @Test func leavingTheSheetGivesEveryPlayerBack() async throws {
        let pool = makePool()
        let controller = sheet(count: 18, pool: pool)
        try laidOut(controller)
        expand(controller)
        await whenAutoplayIsAllowed()
        appear(controller)
        #expect(await bound(GridAutoplayRanking.mosaicPlayers, on: pool) { controller.reconcileAutoplay() },
                "guard: the tiles' players are bound")

        disappear(controller)
        #expect(pool.activePlayerCount == 0, "a tile kept its player after the sheet left")
        #expect(await boundAfterAWhile(pool) == 0, "a player was bound after the sheet left")
    }

    /// Leaving in the very turn the tiles started — their tasks not yet run —
    /// leaves nothing behind either: the race a quick dismissal runs.
    @Test func leavingAsTheTilesStartBindsNothing() async throws {
        let pool = makePool()
        let controller = sheet(count: 18, pool: pool)
        try laidOut(controller)
        expand(controller)
        await whenAutoplayIsAllowed()
        appear(controller)
        #expect(startedCells(try tileCells(of: controller)).count == GridAutoplayRanking.mosaicPlayers,
                "guard: the tiles started")
        disappear(controller)
        #expect(await boundAfterAWhile(pool) == 0, "a start outlived the sheet")
    }

    /// A feed opened from a tile covers the sheet for the trip, and its host
    /// is presented over full screen — no appearance callback reaches the
    /// sheet — so the open itself gives the tiles' players back.
    @Test func aFeedOpenedFromATileStopsTheTiles() async throws {
        let pool = makePool()
        let controller = sheet(count: 18, pool: pool)
        controller.openFeedHero = { _, _, _ in }
        controller.galleryPost = { id in
            GalleryPost(
                id: id, kind: .video, isRepost: false, thumbnailURL: nil, caption: "", publishedAtMS: 1
            )
        }
        try laidOut(controller)
        expand(controller)
        await whenAutoplayIsAllowed()
        appear(controller)
        #expect(await bound(GridAutoplayRanking.mosaicPlayers, on: pool) { controller.reconcileAutoplay() },
                "guard: the tiles' players are bound")

        let order = controller.sections.first { $0.kind == .recent }?.ids ?? []
        controller.debugSelect(try #require(order.first), in: .recent, order: order)
        #expect(pool.activePlayerCount == 0, "the tiles kept playing under the feed")
        // Covered, a reconcile (a cover landing, a layout) starts nothing.
        controller.reconcileAutoplay()
        #expect(await boundAfterAWhile(pool) == 0, "a tile started under the feed")
    }

    /// A pushed section plays its own tiles by the same rules, and gives them
    /// back when it leaves.
    @Test func aPushedSectionPlaysItsTilesAndGivesThemBack() async throws {
        let pool = makePool()
        let ids = (0..<18).map { PostID("g\($0)") }
        let gallery = SoundSheetGalleryViewController(
            kind: .popular, ids: ids,
            tile: { id in
                Sheet.Tile(postID: id, thumbnailURL: nil, caption: nil, isCurrent: false,
                           videoURL: URL(string: "mock://video/\(id.rawValue)"))
            },
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: pool
        )
        gallery.loadViewIfNeeded()
        gallery.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        gallery.view.layoutIfNeeded()
        gallery.grid.layoutIfNeeded()
        let cells = gallery.grid.visibleCells.compactMap { $0 as? SoundSheetTileCell }
        #expect(cells.count >= 9, "guard: three rows on screen")

        await whenAutoplayIsAllowed()
        appear(gallery)
        #expect(startedCells(cells).count == GridAutoplayRanking.mosaicPlayers)
        #expect(await bound(GridAutoplayRanking.mosaicPlayers, on: pool) { gallery.reconcileAutoplay() },
                "guard: the tiles' players are bound")

        disappear(gallery)
        #expect(pool.activePlayerCount == 0, "a pushed section's tile kept its player")
        #expect(await boundAfterAWhile(pool) == 0, "a player was bound after the section left")
    }
}
