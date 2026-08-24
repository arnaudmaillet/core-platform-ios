import CoreModels
import Foundation
import MediaCore
import MediaPlayback
import Testing
import UIKit
@testable import PostGrid

private struct StubVideoSource: VideoSource {
    func playableURL(for url: URL) async throws -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(url.lastPathComponent).mp4")
    }
}

/// A card's carousel keeping its clips warm — and yielding when the feed needs
/// the players more.
///
/// ## What makes this different from the post page
///
/// A post open full-screen is the only thing drawing and may spend the whole
/// pool. A row is one of several, and the coordinator gives every chosen row a
/// player before anything is kept warm. So the row's allowance is what is LEFT
/// OVER, and these pin both halves of that: it uses the spare when there is
/// some, and it behaves exactly as it always did when there is none.
@MainActor
struct RowClipRetentionTests {
    private func url(_ name: String) -> URL { URL(string: "mock://video/\(name)")! }

    /// A row whose pages are `true` for a clip, `false` for a still.
    private func row(_ shape: [Bool], id: String = "p") -> PostGridListRowCell {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        let pages = shape.enumerated().map { index, isClip in
            GalleryPost.MediaPage(
                thumbnailURL: URL(string: "mock://thumb/\(index)"),
                videoURL: isClip ? self.url("clip-\(index)") : nil,
                aspectRatio: 1.5
            )
        }
        cell.configure(
            with: GalleryPost(
                id: PostID(id), kind: .photo, isRepost: false,
                pages: pages, caption: "Short.", publishedAtMS: 0
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let attributes = UICollectionViewLayoutAttributes(
            forCellWith: IndexPath(item: 0, section: 0)
        )
        attributes.frame = cell.frame
        cell.bounds.size.height = cell.preferredLayoutAttributesFitting(attributes).frame.height
        cell.layoutIfNeeded()
        return cell
    }

    // MARK: - With an allowance

    /// ⚠️ THE CHANGE: each clip keeps its own surface, on its own page.
    @Test func aGrantedRowKeepsEachClipOnItsOwnPage() {
        let cell = row([true, true])
        cell.retainClips(budget: 2)
        let first = cell.makeVideoRenderViewIfNeeded()
        let firstPage = first.superview

        cell.debugScrollCarousel(toPage: 1, animated: false)
        cell.retainClips(budget: 2)
        let second = cell.makeVideoRenderViewIfNeeded()

        #expect(second !== first)
        // The clip left behind is still hanging on ITS page, not evicted — which
        // is what keeps its last frame there instead of its thumbnail.
        #expect(first.superview === firstPage)
        #expect(second.superview !== firstPage)
        #expect(cell.retainedPlaybackSurfaces.count == 2)
    }

    /// Coming back finds the same surface, not a fresh one.
    @Test func returningToAClipFindsTheSurfaceItLeft() {
        let cell = row([true, true])
        cell.retainClips(budget: 2)
        let first = cell.makeVideoRenderViewIfNeeded()

        cell.debugScrollCarousel(toPage: 1, animated: false)
        cell.retainClips(budget: 2)
        _ = cell.makeVideoRenderViewIfNeeded()
        cell.debugScrollCarousel(toPage: 0, animated: false)
        cell.retainClips(budget: 2)

        #expect(cell.makeVideoRenderViewIfNeeded() === first)
    }

    /// Stills are not candidates: a gallery of photographs around one clip
    /// keeps one surface however generous the budget.
    @Test func photographsAreNotKept() {
        let cell = row([true, false, false])
        cell.retainClips(budget: 5)
        _ = cell.makeVideoRenderViewIfNeeded()
        cell.debugScrollCarousel(toPage: 1, animated: false)
        cell.retainClips(budget: 5)

        #expect(cell.retainedPlaybackSurfaces.count == 1)
    }

    /// The allowance bounds it: three clips, room for one extra.
    @Test func theAllowanceIsARealCeiling() {
        let cell = row([true, true, true])
        for page in 0..<3 {
            cell.debugScrollCarousel(toPage: page, animated: false)
            cell.retainClips(budget: 1)
            _ = cell.makeVideoRenderViewIfNeeded()
            // The watched clip plus one kept — never the whole gallery.
            #expect(cell.retainedPlaybackSurfaces.count <= 2)
        }
    }

    // MARK: - Without one

    /// ⚠️ ZERO IS THE OLD BEHAVIOUR, EXACTLY — asserted, not assumed.
    ///
    /// The coordinator reads "this row holds more than one surface" to decide it
    /// may release a loan rather than stop it. A row that helped itself to a
    /// second surface with no allowance would therefore leave the previous
    /// clip's player bound, untracked and unreclaimable — so a granted row and
    /// an ungranted one must differ here, and the difference is asserted next to
    /// its opposite above.
    @Test func anUngrantedRowStillMovesItsOneSurface() {
        let cell = row([true, true])
        cell.retainClips(budget: 0)
        let first = cell.makeVideoRenderViewIfNeeded()
        let firstPage = first.superview

        cell.debugScrollCarousel(toPage: 1, animated: false)
        cell.retainClips(budget: 0)
        let second = cell.makeVideoRenderViewIfNeeded()

        #expect(second === first)
        #expect(second.superview !== firstPage)
        #expect(cell.retainedPlaybackSurfaces.count == 1)
    }

    /// Losing the allowance gives the extra surfaces back.
    @Test func withdrawingTheAllowanceReleasesWhatItBought() {
        let cell = row([true, true])
        cell.retainClips(budget: 2)
        _ = cell.makeVideoRenderViewIfNeeded()
        cell.debugScrollCarousel(toPage: 1, animated: false)
        cell.retainClips(budget: 2)
        _ = cell.makeVideoRenderViewIfNeeded()
        #expect(cell.retainedPlaybackSurfaces.count == 2)

        let dropped = cell.retainClips(budget: 0)

        #expect(dropped.count == 1)
        #expect(cell.retainedPlaybackSurfaces.count == 1)
    }

    // MARK: - Ready before the viewer

    /// ⚠️ Prepared AND HOSTED AND POSTERED — all three, or the fix is a defect.
    ///
    /// A surface hung on a page with no poster is a black rectangle over the
    /// photograph until the stream fills, which is worse than the delay the
    /// warming removes. So the surface being ready is not enough to assert.
    @Test func aGrantedRowPreparesTheClipsWithinASwipe() {
        let cell = row([true, true, true])
        cell.retainClips(budget: 3)

        let clips = cell.clipsToPrewarm()

        #expect(clips.count == CarouselRetentionWindow.prewarmDepth)
        #expect(clips.allSatisfy { $0.surface.superview != nil })
        #expect(clips.allSatisfy { !$0.surface.isHidden })
        // Not the page being watched: its player is already being started, and
        // warming it again would restart what is running.
        #expect(clips.allSatisfy { $0.surface !== cell.loadedVideoRenderView })
    }

    /// And a row with no allowance prepares nothing at all — the spare is the
    /// ceiling on warming exactly as it is on keeping.
    @Test func anUngrantedRowPreparesNothing() {
        let cell = row([true, true, true])
        cell.retainClips(budget: 0)

        #expect(cell.clipsToPrewarm().isEmpty)
    }

    /// ⚠️ A LANDING'S SURFACE MUST BE FINDABLE, or its clip never stops.
    ///
    /// The hero flight hands the row a live surface. If the page map still names
    /// the one it replaced, the live view is in no map at all — and the pause
    /// pass walks that map, so nothing can pause the player it carries. It runs
    /// for the life of the row, and returning to its page finds playback seconds
    /// ahead, with the picture racing to reach it.
    ///
    /// Observed as the card and the post behaving differently: the post's card
    /// view took this line when its landing was fixed, and the row did not.
    @Test func aLandingPutsItsSurfaceInThePageMap() {
        let cell = row([true, true])
        cell.retainClips(budget: 2)
        let replaced = cell.makeVideoRenderViewIfNeeded()

        let flown = VideoRenderView()
        cell.adoptVideoRenderView(flown)

        #expect(cell.watchedClipSurface === flown)
        #expect(cell.retainedPlaybackSurfaces.contains { $0 === flown })
        // And the one it replaced is gone, so nothing is paused twice or held
        // by a page that no longer draws it.
        #expect(cell.retainedPlaybackSurfaces.contains { $0 === replaced } == false)
    }

    // MARK: - Where the mark sits

    /// ⚠️ THE CORNER, and the SAME corner the row's own badge uses.
    ///
    /// A single-video card has always put its play badge at the media's top
    /// trailing corner. Only a carousel's pages sat it in the middle, so a
    /// collection and a single clip disagreed about where the mark lives — and
    /// the collection's version covered the photograph it was describing.
    ///
    /// Asserted as a QUADRANT rather than a coordinate: the exact inset is the
    /// card's furniture rule and may move with it, but "top trailing, off the
    /// edge, clear of the middle" is the decision.
    @Test func aVideoPagesMarkSitsInTheTopTrailingCorner() {
        let cell = row([true, true])
        let carousel = cell.debugCarousel
        let page = try? #require(carousel?.pageViews.first)
        let badge = try? #require(page?.badge)
        let bounds = try? #require(page?.bounds)
        guard let badge, let bounds, bounds.width > 0 else {
            Issue.record("the page was never laid out, so its badge proves nothing")
            return
        }

        #expect(badge.frame.maxX <= bounds.maxX)
        #expect(badge.frame.minX > bounds.midX)
        #expect(badge.frame.maxY < bounds.midY)
        // Clear of the centre it used to occupy.
        #expect(badge.frame.contains(CGPoint(x: bounds.midX, y: bounds.midY)) == false)
    }

    // MARK: - Hold to pause

    /// A finger resting on the media stops the clip, and lifting it starts
    /// again.
    @Test func holdingStopsTheClipAndReleasingResumesIt() async {
        let pool = VideoPlaybackController(
            source: StubVideoSource(), poolSize: 6, capacity: 6
        )
        let coordinator = GridVideoPlaybackCoordinator(pool: pool, maxConcurrent: 6)
        let cell = row([true], id: "post-0")
        coordinator.setSurfaceVisible(true)
        coordinator.update(candidates: [
            .init(id: PostID("post-0"), url: url("clip-0"),
                  cell: cell, distanceFromCentre: 0)
        ])
        _ = cell.makeVideoRenderViewIfNeeded()
        await settle { pool.isAdvancing(in: (cell.watchedClipSurface ?? cell.makeVideoRenderViewIfNeeded())) }
        #expect(pool.isAdvancing(in: (cell.watchedClipSurface ?? cell.makeVideoRenderViewIfNeeded())), "nothing was playing to hold")

        coordinator.setHeld(true, for: PostID("post-0"))
        #expect(pool.isAdvancing(in: (cell.watchedClipSurface ?? cell.makeVideoRenderViewIfNeeded())) == false)

        coordinator.setHeld(false, for: PostID("post-0"))
        #expect(pool.isAdvancing(in: (cell.watchedClipSurface ?? cell.makeVideoRenderViewIfNeeded())))
    }

    /// ⚠️ RELEASING UNDOES THE HOLD, AND NOTHING ELSE.
    ///
    /// A clip that was already stopped — one page over, or resting because its
    /// row lost the ranking — must not start playing because a finger happened
    /// to rest on it and lift. The hold resumes what it stopped; it is not a
    /// second way to press play.
    @Test func releasingDoesNotStartAClipTheHoldNeverStopped() async {
        let pool = VideoPlaybackController(
            source: StubVideoSource(), poolSize: 6, capacity: 6
        )
        let coordinator = GridVideoPlaybackCoordinator(pool: pool, maxConcurrent: 6)
        let cell = row([true], id: "post-0")
        coordinator.setSurfaceVisible(true)
        coordinator.update(candidates: [
            .init(id: PostID("post-0"), url: url("clip-0"),
                  cell: cell, distanceFromCentre: 0, isPaused: true)
        ])
        _ = cell.makeVideoRenderViewIfNeeded()
        await settle { pool.hasPlayer(in: (cell.watchedClipSurface ?? cell.makeVideoRenderViewIfNeeded())) }
        // ⚠️ The denominator. "Still not advancing" is satisfied by a clip that
        // never had a player at all, which would make this test agree with any
        // implementation whatsoever.
        #expect(pool.hasPlayer(in: (cell.watchedClipSurface ?? cell.makeVideoRenderViewIfNeeded())),
                "no player was ever bound, so nothing below means anything")
        pool.setPaused(true, in: (cell.watchedClipSurface ?? cell.makeVideoRenderViewIfNeeded()))
        #expect(pool.isAdvancing(in: (cell.watchedClipSurface ?? cell.makeVideoRenderViewIfNeeded())) == false)

        coordinator.setHeld(true, for: PostID("post-0"))
        coordinator.setHeld(false, for: PostID("post-0"))

        #expect(pool.isAdvancing(in: (cell.watchedClipSurface ?? cell.makeVideoRenderViewIfNeeded())) == false)
    }

    // MARK: - One at a time

    private func settle(until condition: () -> Bool, tries: Int = 400) async {
        for _ in 0..<tries where !condition() {
            await Task.yield()
        }
    }

    /// ⚠️ ONE CLIP PLAYS IN A CAROUSEL. EVER.
    ///
    /// Reported from the feed: paging a card's carousel left the previous clip
    /// running, so several played at once. The cause is an ordering the post
    /// page had already been bitten by — the pause pass read
    /// `loadedVideoRenderView`, which is only re-pointed when a caller asks for
    /// a surface, and that happens in the START pass afterwards. So the pause
    /// spared the page just LEFT and paused the one arriving.
    @Test func onlyOneClipPlaysAtATimeInACarousel() async {
        let pool = VideoPlaybackController(
            source: StubVideoSource(), poolSize: 6, capacity: 6
        )
        let coordinator = GridVideoPlaybackCoordinator(pool: pool, maxConcurrent: 6)
        let cell = row([true, true], id: "post-0")
        coordinator.setSurfaceVisible(true)

        func reconcile(page: Int) async {
            coordinator.update(candidates: [
                .init(id: PostID("post-0"), url: self.url("clip-\(page)"),
                      cell: cell, distanceFromCentre: 0)
            ])
            _ = cell.makeVideoRenderViewIfNeeded()
            // ⚠️ Wait for what is ASSERTED, not for a proxy of it. Waiting on a
            // player count and then asserting that one is ADVANCING leaves a
            // window where the count is right and the resume has not landed —
            // measured as an intermittent failure, one run in four.
            await settle {
                guard let watched = cell.watchedClipSurface else { return false }
                return pool.isAdvancing(in: watched)
            }
        }

        await reconcile(page: 0)
        cell.debugScrollCarousel(toPage: 1, animated: false)
        await reconcile(page: 1)

        // The denominator: two clips really are being held, so the count below
        // is a choice between them rather than an empty set.
        #expect(cell.retainedPlaybackSurfaces.count == 2)
        let advancing = cell.retainedPlaybackSurfaces.filter { pool.isAdvancing(in: $0) }
        #expect(advancing.count <= 1)
        // And it is the page the viewer is ON that plays, not whichever survived.
        #expect(advancing.first === cell.watchedClipSurface)
    }

    /// ⚠️ ARRIVING AT A WARMED CLIP MUST NOT RESTART IT.
    ///
    /// The whole purpose of warming is that the picture is already there. The
    /// coordinator started it anyway — `play` on a surface already bound to the
    /// asset replaces the item and begins at zero — so the preparation was paid
    /// for and thrown away, and the viewer saw the clip jump back to its start.
    ///
    /// Item creations are the measurement because nothing else distinguishes a
    /// resumed clip from a restarted one from outside.
    @Test func arrivingAtAWarmedClipResumesItInsteadOfRestarting() async {
        let pool = VideoPlaybackController(
            source: StubVideoSource(), poolSize: 6, capacity: 6
        )
        let coordinator = GridVideoPlaybackCoordinator(pool: pool, maxConcurrent: 6)
        let cell = row([true, true], id: "post-0")
        coordinator.setSurfaceVisible(true)

        coordinator.update(candidates: [
            .init(id: PostID("post-0"), url: url("clip-0"),
                  cell: cell, distanceFromCentre: 0)
        ])
        _ = cell.makeVideoRenderViewIfNeeded()
        // Both clips bound: the watched one, and the neighbour warmed for it.
        await settle { pool.activePlayerCount >= 2 }
        #expect(pool.activePlayerCount == 2, "the neighbour was never warmed")
        let itemsBeforeArriving = pool.itemCreations

        cell.debugScrollCarousel(toPage: 1, animated: false)
        coordinator.update(candidates: [
            .init(id: PostID("post-0"), url: url("clip-1"),
                  cell: cell, distanceFromCentre: 0)
        ])
        _ = cell.makeVideoRenderViewIfNeeded()
        // ⚠️ DRAINED, not sampled. A restart happens on the far side of the
        // pool's await, while the resume is synchronous — so a test that
        // measured as soon as the clip was advancing saw the resume, missed the
        // restart entirely, and passed against the broken code. It did: this
        // assertion was green before the fix existed.
        for _ in 0..<600 { await Task.yield() }

        // Nothing new was decoded: the clip the viewer arrived at is the one
        // that was waiting for them.
        #expect(pool.itemCreations == itemsBeforeArriving)
        #expect(pool.isAdvancing(in: cell.watchedClipSurface!))
    }

    // MARK: - Sharing the pool

    /// ⚠️ THE BUDGET IS IN PLAYERS, NOT ROWS.
    ///
    /// A screen full of playing rows leaves nothing spare, and the retention
    /// yields rather than competing. Driven through the coordinator because the
    /// division is its decision, not the row's.
    @Test func afullScreenOfRowsLeavesNothingToKeepWarm() async {
        let pool = VideoPlaybackController(
            source: StubVideoSource(), poolSize: 3, capacity: 3
        )
        let coordinator = GridVideoPlaybackCoordinator(pool: pool, maxConcurrent: 3)
        let rows = (0..<3).map { row([true, true], id: "post-\($0)") }
        coordinator.setSurfaceVisible(true)

        func reconcile(page: Int) {
            coordinator.update(candidates: rows.enumerated().map { index, cell in
                .init(id: PostID("post-\(index)"), url: self.url("clip-\(page)"),
                      cell: cell, distanceFromCentre: CGFloat(index))
            })
            for cell in rows { _ = cell.makeVideoRenderViewIfNeeded() }
        }

        // ⚠️ Driven exactly like `aLoneRowMaySpendTheSpare`, its opposite. A
        // `<=` on a row that never got a surface at all would pass while proving
        // nothing, so the row is put through the same page change that makes the
        // lone row grow — and asserted NOT to grow.
        reconcile(page: 0)
        for cell in rows { cell.debugScrollCarousel(toPage: 1, animated: false) }
        reconcile(page: 1)

        for cell in rows {
            #expect(cell.retainedPlaybackSurfaces.count == 1)
        }
    }

    /// And the converse: one row on screen may spend what the others are not
    /// using. Asserted beside the case above, because a version that always
    /// granted zero would pass that one and defeat the whole feature.
    @Test func aLoneRowMaySpendTheSpare() async {
        let pool = VideoPlaybackController(
            source: StubVideoSource(), poolSize: 6, capacity: 6
        )
        let coordinator = GridVideoPlaybackCoordinator(pool: pool, maxConcurrent: 6)
        let cell = row([true, true], id: "post-0")
        coordinator.setSurfaceVisible(true)

        coordinator.update(candidates: [
            .init(id: PostID("post-0"), url: url("clip-0"),
                  cell: cell, distanceFromCentre: 0)
        ])
        _ = cell.makeVideoRenderViewIfNeeded()
        cell.debugScrollCarousel(toPage: 1, animated: false)
        coordinator.update(candidates: [
            .init(id: PostID("post-0"), url: url("clip-1"),
                  cell: cell, distanceFromCentre: 0)
        ])
        _ = cell.makeVideoRenderViewIfNeeded()

        #expect(cell.retainedPlaybackSurfaces.count == 2)
    }
}
