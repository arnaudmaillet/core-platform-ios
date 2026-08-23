import CoreModels
import MediaCore
import MediaPlayback
import PostGrid
import Testing
import UIKit
@testable import Feed

/// How many players a post holds while the viewer moves through its clips.
///
/// ## What these are for
///
/// The rule is one player per clip the viewer has reached, bounded by what the
/// pool says it can carry, and **never a second player for a clip that already
/// has one** — no matter how many times the post is opened, paged through and
/// closed. Every defect this feature has produced was a disagreement about that
/// sentence, so it is asserted from the outside: the questions are put to the
/// POOL, never to the cell's own bookkeeping, because a cell that has lost
/// track answers confidently and wrongly.
///
/// `VideoPoolIdentityTests` pins the same invariant one layer down, on the pool
/// alone. These pin it through the thing that actually drives it.
@MainActor
struct CarouselRetentionTests {
    /// Waits for playback the cell starts on its own clock, bounded so a
    /// regression fails rather than hangs.
    private func settle(until condition: () -> Bool, tries: Int = 400) async {
        for _ in 0..<tries where !condition() {
            await Task.yield()
        }
    }

    private func url(_ name: String) -> URL { URL(string: "mock://video/\(name)")! }

    /// A post whose pages are given as `true` for a clip, `false` for a still.
    private func collectionCell(
        _ shape: [Bool], pool: VideoPlaybackController, id: String = "post-collection"
    ) -> SnapFeedCell {
        let cell = SnapFeedCell(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let head = shape.first ?? false
        let extra = shape.dropFirst().enumerated().map { offset, isClip in
            GalleryPost.MediaPage(
                thumbnailURL: self.url("thumb-\(offset + 1)"),
                videoURL: isClip ? self.url("clip-\(offset + 1)") : nil
            )
        }
        cell.configure(
            with: FeedItemDisplayModel(
                id: PostID(id),
                authorID: ProfileID("profile-1"),
                authorName: "Ava",
                metaText: "@ava · 3m",
                avatarURL: nil,
                caption: "caption",
                mediaURL: url("clip-0"),
                mediaKind: head ? .video : .image,
                thumbnailURL: url("thumb-0"),
                audioText: nil,
                likeCount: 0,
                timestampText: "now",
                extraMedia: Array(extra)
            ),
            pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: pool
        )
        cell.layoutIfNeeded()
        cell.willBecomeActive()
        return cell
    }

    /// Visits each page in turn and waits for playback to bind.
    private func page(_ cell: SnapFeedCell, through pages: [Int],
                      pool: VideoPlaybackController) async {
        for index in pages {
            cell.debugShowPage(index)
            await settle { pool.hasPlayer(in: cell.debugRenderSurface) }
        }
    }

    private func pool(capacity: Int = 6) -> VideoPlaybackController {
        VideoPlaybackController(
            source: StubVideoSource(), poolSize: capacity, capacity: capacity
        )
    }

    // MARK: - One clip, one player

    /// ⚠️ THE CENTRAL CLAIM: as many players as clips visited, never more.
    @Test func eachVisitedClipHoldsExactlyOnePlayer() async {
        let pool = pool()
        let cell = collectionCell([true, true, true], pool: pool)

        await page(cell, through: [0, 1, 2], pool: pool)

        #expect(pool.activePlayerCount == 3)
        #expect(pool.playerCountByURL.values.allSatisfy { $0 == 1 })
    }

    /// The same, asserted the other way round — no URL is ever behind two
    /// surfaces. A pool that duplicated on every visit would still satisfy a
    /// count-only test if it dropped one elsewhere.
    @Test func noClipIsEverBehindTwoPlayers() async {
        let pool = pool()
        let cell = collectionCell([true, false, true, true], pool: pool)

        await page(cell, through: [0, 2, 3, 0, 2, 3, 0], pool: pool)

        #expect(pool.playerCountByURL.values.allSatisfy { $0 == 1 })
    }

    /// ⚠️ THE CLAIM THE WHOLE FEATURE MAKES: a clip the viewer has left still
    /// has its player while they are somewhere else.
    ///
    /// This is what "keeps its last frame instead of its thumbnail" means from
    /// the pool's side, and it is asserted directly rather than through a count,
    /// which a version that stopped one clip and started another would satisfy.
    @Test func aClipLeftBehindKeepsItsPlayer() async {
        let pool = pool()
        let cell = collectionCell([true, true], pool: pool)

        await page(cell, through: [0, 1], pool: pool)

        #expect(cell.debugSurfacedPages == [0, 1])
        #expect(pool.hasPlayer(in: cell.debugSurface(forPage: 0)))
        #expect(pool.hasPlayer(in: cell.debugSurface(forPage: 1)))
        // Two surfaces, two players, and the two are not the same view — the
        // single-surface design would put both answers on one object.
        #expect(cell.debugSurface(forPage: 0) !== cell.debugSurface(forPage: 1))
    }

    /// Returning to a clip must RESUME it, not decode it again.
    @Test func aRevisitedClipReusesItsPlayer() async {
        let pool = pool()
        let cell = collectionCell([true, true], pool: pool)

        await page(cell, through: [0, 1], pool: pool)
        let afterFirstPass = pool.activePlayerCount
        let pageZeroSurface = cell.debugSurface(forPage: 0)
        await page(cell, through: [0, 1, 0, 1], pool: pool)

        #expect(pool.activePlayerCount == afterFirstPass)
        // ⚠️ And it is the SAME surface it started with. A count alone cannot
        // tell "resumed" from "stopped and re-created", which is exactly the
        // pair of states this test exists to separate.
        #expect(cell.debugSurface(forPage: 0) === pageZeroSurface)
    }

    // MARK: - The bound

    /// ⚠️ The case the whole window exists for: more clips than the pool can
    /// carry.
    @Test func aGalleryLargerThanCapacityNeverExceedsIt() async {
        let pool = pool(capacity: 2)
        let cell = collectionCell(Array(repeating: true, count: 6), pool: pool)

        for index in 0..<6 {
            cell.debugShowPage(index)
            await settle { pool.hasPlayer(in: cell.debugRenderSurface) }
            // Checked at EVERY step, not once at the end — a window that
            // overshot and then tidied up would pass a final-state assertion
            // while starving the decoder in the middle.
            #expect(pool.activePlayerCount <= pool.capacity)
        }
        #expect(pool.activePlayerCount <= 2)
    }

    /// ⚠️ EXACTLY the budget, not one more — the off-by-one a falsifying run
    /// exposed and no amount of reading the code had.
    ///
    /// The window was applied while `renderView` still named the page the
    /// viewer had just left, and the eviction spared it: one clip past the
    /// bound survived every single page change, so the ceiling the whole design
    /// rests on quietly was not one. Counting SURFACES as well as players is
    /// what makes it visible — the extra one was held, paused, and invisible to
    /// a player count that had already stopped it.
    @Test func theBudgetHoldsExactlyAndNotOneMore() async {
        let pool = pool(capacity: 2)
        let cell = collectionCell([true, true, true, true], pool: pool)

        for index in 0..<4 {
            cell.debugShowPage(index)
            await settle { pool.hasPlayer(in: cell.debugRenderSurface) }
            #expect(cell.debugSurfacedPages.count <= 2)
            #expect(pool.activePlayerCount <= 2)
        }
    }

    /// Stills are not candidates and must not consume any of the budget.
    @Test func photographsHoldNoPlayers() async {
        let pool = pool()
        let cell = collectionCell([false, false, true, false], pool: pool)

        await page(cell, through: [0, 1, 2, 3], pool: pool)

        #expect(pool.activePlayerCount == 1)
    }

    /// Only the watched clip advances; the kept ones hold their frame.
    ///
    /// ⚠️ THE DENOMINATOR IS ASSERTED FIRST, and it is not decoration. This
    /// walks the retained pages — so a version that retained nothing would run
    /// the loop zero times and report a pass, which is the same shape as an
    /// empty log reading like a clean one. The count is what makes the loop's
    /// silence mean something.
    @Test func onlyTheWatchedClipIsAdvancing() async {
        let pool = pool()
        let cell = collectionCell([true, true, true], pool: pool)
        await page(cell, through: [0, 1, 2], pool: pool)

        let kept = cell.debugSurfacedPages.filter { $0 != 2 }
        #expect(kept == [0, 1])
        for page in kept {
            #expect(pool.hasPlayer(in: cell.debugSurface(forPage: page)))
            #expect(pool.isAdvancing(in: cell.debugSurface(forPage: page)) == false)
        }
    }

    // MARK: - Ready before the viewer

    /// ⚠️ THE OTHER HALF: the clip one swipe away already has a picture.
    ///
    /// Retention makes the RETURN to a clip free; it does nothing for the first
    /// arrival, which is still a cold decode — the thumbnail-then-video delay
    /// the viewer reported. This is what removes it.
    @Test func theNextClipIsReadyBeforeTheViewerArrives() async {
        let pool = pool()
        let cell = collectionCell([true, true, true], pool: pool)

        // Through the same door as every other test: `debugShowPage` alone does
        // not necessarily move anything when the carousel is already on that
        // page, and a warm-up that never ran looks exactly like one that failed.
        await page(cell, through: [0], pool: pool)
        await settle { cell.debugSurfacedPages.contains(1) }
        #expect(cell.debugSurfacedPages.contains(1), "page one was never prepared")

        let ahead = cell.debugSurface(forPage: 1)
        await settle { pool.hasPlayer(in: ahead) }
        #expect(pool.hasPlayer(in: ahead))
        // Ready, and NOT running: a warmed clip holds its frame rather than
        // playing unseen beside the one on screen.
        #expect(pool.isAdvancing(in: ahead) == false)
    }

    /// ⚠️ A COLLECTION THAT OPENS ON A PHOTOGRAPH WARMS ITS CLIPS ANYWAY.
    ///
    /// Warming hung only off the paths that start playback, so a post whose
    /// first page is a still prepared nothing and every clip in it was met cold
    /// — which is the whole of the complaint. Caught in the simulator by the
    /// probe reading `kept=0`, not by any of the tests written before it.
    @Test func aPostOpeningOnAStillStillWarmsItsClips() async {
        let pool = pool()
        let cell = collectionCell([false, false, true, true], pool: pool)

        await settle { pool.activePlayerCount >= 1 }

        #expect(pool.activePlayerCount >= 1, "a still first page warmed nothing")
        #expect(cell.debugSurfacedPages.contains(2))
    }

    /// Warming must not duplicate: the clip being watched keeps the one player
    /// it already has.
    @Test func warmingNeverGivesAClipASecondPlayer() async {
        let pool = pool()
        let cell = collectionCell([true, true, true], pool: pool)

        await page(cell, through: [0, 1, 2, 1, 0], pool: pool)

        #expect(pool.playerCountByURL.values.allSatisfy { $0 == 1 })
    }

    /// And it respects the ceiling like everything else.
    @Test func warmingStaysInsideTheBudget() async {
        let pool = pool(capacity: 2)
        let cell = collectionCell([true, true, true, true], pool: pool)

        cell.debugShowPage(0)
        await settle { pool.activePlayerCount >= 2 }

        #expect(pool.activePlayerCount <= 2)
    }

    // MARK: - Opening and closing, over and over

    /// ⚠️ THE ACCUMULATION TEST. Whatever the number of opens and closes, the
    /// post ends holding what it started with.
    @Test func repeatedOpensAndClosesDoNotAccumulate() async {
        let pool = pool()
        var counts: [Int] = []

        for _ in 0..<5 {
            let cell = collectionCell([true, true, true], pool: pool)
            await page(cell, through: [0, 1, 2, 1, 0], pool: pool)
            counts.append(pool.activePlayerCount)
            // Closing the post, the way the feed closes it.
            cell.didResignActive(releasingPlayback: true)
            #expect(pool.activePlayerCount == 0)
        }

        // Every visit cost the same — a leak would make this climb.
        #expect(Set(counts).count == 1)
    }

    @Test func leavingThePostReleasesEveryKeptClip() async {
        let pool = pool()
        let cell = collectionCell([true, true, true], pool: pool)
        await page(cell, through: [0, 1, 2], pool: pool)
        #expect(pool.activePlayerCount == 3)

        cell.didResignActive(releasingPlayback: true)

        #expect(pool.activePlayerCount == 0)
    }

    /// Reuse is the other door out, and the one a leak escapes through
    /// unnoticed: nothing on screen changes when it goes wrong.
    @Test func reuseReleasesEveryKeptClip() async {
        let pool = pool()
        let cell = collectionCell([true, true], pool: pool)
        await page(cell, through: [0, 1], pool: pool)

        cell.prepareForReuse()

        #expect(pool.activePlayerCount == 0)
    }

    /// Paging away from the post but STAYING in the feed keeps the clips —
    /// asserted next to its opposite, because a version that released on both
    /// would pass the release tests and reintroduce the reported cut.
    @Test func pagingWithinTheFeedKeepsTheClips() async {
        let pool = pool()
        let cell = collectionCell([true, true], pool: pool)
        await page(cell, through: [0, 1], pool: pool)
        let held = pool.activePlayerCount

        cell.didResignActive(releasingPlayback: false)

        #expect(pool.activePlayerCount == held)
    }
}

/// Resolves to a stable local URL so `play` binds without a network.
private struct StubVideoSource: VideoSource {
    func playableURL(for mediaURL: URL) async throws -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(mediaURL.lastPathComponent).mp4")
    }
}
