import MediaPlayback
import Testing
import UIKit
@testable import Feed

/// The viewer's hand on a post page's clip (`SnapCellPlayback`), against a
/// real pool and a stub source: the tap, the hold, the sheet, the playhead
/// feed and the scrub — who paused the clip, and who may resume it.
///
/// ⚠️ No decoder here. A stub clip runs (the pool's player is told to play)
/// but has no length, so it reports no playhead and gives no preview frame:
/// these cases prove what the player was TOLD, never which frames it drew.
@MainActor
struct SnapCellPlaybackTests {
    // MARK: - Fixtures

    private struct StubSource: VideoSource {
        func playableURL(for url: URL) async throws -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("stub.mp4")
        }
    }

    private static let clip = URL(string: "mock://video/trailer")!

    /// The page the playback asks: which surface is watched, and whether the
    /// page is the active one.
    private final class Page {
        var isActive = true
        let surface: VideoRenderView

        init(surface: VideoRenderView) { self.surface = surface }
    }

    /// A page playing a clip, and the playback driving it.
    private static func playingPage() async
        -> (playback: SnapCellPlayback, pool: VideoPlaybackController, page: Page) {
        let pool = VideoPlaybackController(source: StubSource(), poolSize: 2, capacity: 2)
        let surface = VideoRenderView()
        surface.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        await pool.play(clip, in: surface, scope: "post-video")
        let page = Page(surface: surface)
        let playback = SnapCellPlayback(
            surface: { [page] in page.surface },
            isActive: { [page] in page.isActive }
        )
        playback.pool = pool
        return (playback, pool, page)
    }

    /// Lets the playback's own tasks run, a bounded number of looks — never a
    /// clock.
    private static func settle(looks: Int = 500, until done: () -> Bool) async {
        for _ in 0..<looks {
            if done() { return }
            await Task.yield()
        }
    }

    // MARK: - The tap

    @Test func aTapPausesARunningClipAndASecondTapResumesIt() async {
        let (playback, pool, page) = await Self.playingPage()
        #expect(pool.isAdvancing(in: page.surface))

        #expect(playback.toggle() == true)
        #expect(pool.isAdvancing(in: page.surface) == false)

        #expect(playback.toggle() == false)
        #expect(pool.isAdvancing(in: page.surface))
    }

    @Test func aTapWithNoPoolAnswersNothing() async {
        let (playback, pool, page) = await Self.playingPage()
        playback.pool = nil

        #expect(playback.toggle() == nil)
        #expect(pool.isAdvancing(in: page.surface))
    }

    // MARK: - The hold

    @Test func aHoldStopsTheClipUntilItIsReleased() async {
        let (playback, pool, page) = await Self.playingPage()

        playback.beginHold()
        #expect(pool.isAdvancing(in: page.surface) == false)

        playback.endHold()
        #expect(pool.isAdvancing(in: page.surface))
    }

    @Test func aHoldOnAClipTheViewerPausedLeavesItPausedAfterTheRelease() async {
        let (playback, pool, page) = await Self.playingPage()
        _ = playback.toggle()

        playback.beginHold()
        playback.endHold()

        #expect(pool.isAdvancing(in: page.surface) == false)
    }

    @Test func aReleaseWithNoHoldBeforeItChangesNothing() async {
        let (playback, pool, page) = await Self.playingPage()
        _ = playback.toggle()

        playback.endHold()

        #expect(pool.isAdvancing(in: page.surface) == false)
    }

    // MARK: - The sheet

    @Test func aSheetPausesARunningClipAndResumesItWhenItLeaves() async {
        let (playback, pool, page) = await Self.playingPage()

        playback.setCovered(true, on: page.surface)
        #expect(pool.isAdvancing(in: page.surface) == false)

        playback.setCovered(false, on: page.surface)
        #expect(pool.isAdvancing(in: page.surface))
    }

    @Test func aClipPausedBeforeTheSheetStaysPausedAfterIt() async {
        let (playback, pool, page) = await Self.playingPage()
        _ = playback.toggle()

        playback.setCovered(true, on: page.surface)
        playback.setCovered(false, on: page.surface)

        #expect(pool.isAdvancing(in: page.surface) == false)
    }

    // MARK: - The playhead feed

    @Test func theFeedPublishesAtOnceAndRunsUntilItIsStopped() async {
        let (playback, _, _) = await Self.playingPage()
        var published: [(fraction: Double?, seconds: Double)] = []
        playback.onPlayhead = { published.append(($0, $1)) }

        playback.startPlayheadFeed()
        #expect(playback.isFeedingPlayhead)
        // A clip whose length is not known has no playhead: nil, not zero.
        #expect(published.count == 1)
        #expect(published.first?.fraction == nil)

        playback.stopPlayheadFeed()
        #expect(playback.isFeedingPlayhead == false)
        #expect(published.last?.fraction == nil)
        #expect(published.last?.seconds == 0)
    }

    @Test func aSecondStartKeepsOneFeedAndOneStopEndsIt() async {
        let (playback, _, _) = await Self.playingPage()
        var published = 0
        playback.onPlayhead = { _, _ in published += 1 }

        playback.startPlayheadFeed()
        playback.startPlayheadFeed()
        #expect(published == 2)

        playback.stopPlayheadFeed()
        #expect(playback.isFeedingPlayhead == false)
    }

    // MARK: - The scrub

    @Test func aScrubPausesTheClipAndTheReleaseResumesIt() async {
        let (playback, pool, page) = await Self.playingPage()

        playback.beginScrub()
        #expect(pool.isAdvancing(in: page.surface) == false)

        // No seek in flight: the release resumes at once.
        playback.endScrub(at: nil)
        #expect(pool.isAdvancing(in: page.surface))
    }

    @Test func aClipPausedBeforeTheScrubStaysPausedAfterIt() async {
        let (playback, pool, page) = await Self.playingPage()
        _ = playback.toggle()

        playback.beginScrub()
        playback.endScrub(at: nil)

        #expect(pool.isAdvancing(in: page.surface) == false)
    }

    @Test func aPageThatStoppedBeingWatchedMidScrubStaysStopped() async {
        let (playback, pool, page) = await Self.playingPage()

        playback.beginScrub()
        page.isActive = false
        playback.endScrub(at: nil)

        #expect(pool.isAdvancing(in: page.surface) == false)
    }

    @Test func aRecycledPageOwesNoResumeToTheDragBeforeIt() async {
        let (playback, pool, page) = await Self.playingPage()

        playback.beginScrub()
        playback.reset()
        playback.endScrub(at: nil)

        #expect(pool.isAdvancing(in: page.surface) == false)
    }

    // MARK: - The recycle

    @Test func aRecycledPageOwesNoResumeToAHoldBeforeIt() async {
        let (playback, pool, page) = await Self.playingPage()

        playback.beginHold()
        playback.reset()
        // The next post's hold ending in `.failed` or `.cancelled`.
        playback.endHold()

        #expect(pool.isAdvancing(in: page.surface) == false)
    }

    @Test func aRecycledPageOwesNoResumeToASheetBeforeIt() async {
        let (playback, pool, page) = await Self.playingPage()

        playback.setCovered(true, on: page.surface)
        playback.reset()
        playback.setCovered(false, on: page.surface)

        #expect(pool.isAdvancing(in: page.surface) == false)
    }

    @Test func aRecycledPageFetchesItsFirstPreviewAtOnce() async {
        let (playback, _, _) = await Self.playingPage()
        var loading: [Bool] = []
        playback.onScrubPreviewLoading = { loading.append($0) }

        playback.updateScrubPreview(0.2)
        playback.reset()
        playback.updateScrubPreview(0.7)

        // The old post's fetch in flight does not hold the new one back.
        #expect(loading == [true, true])
        await Self.settle { loading.last == false }
    }

    @Test func theFeedStopsItselfOnceItsPageIsGone() async {
        let pool = VideoPlaybackController(source: StubSource(), poolSize: 2, capacity: 2)
        var page: Page? = Page(surface: VideoRenderView())
        let playback = SnapCellPlayback(
            surface: { [weak page] in page?.surface },
            isActive: { true }
        )
        playback.pool = pool
        playback.startPlayheadFeed()
        #expect(playback.isFeedingPlayhead)

        page = nil
        playback.publishPlayhead()

        #expect(page == nil)
        #expect(playback.isFeedingPlayhead == false)
    }

    // MARK: - The scrub preview

    @Test func aRequestWhileOneIsInFlightWaitsThenFetchesTheLatest() async {
        let (playback, _, _) = await Self.playingPage()
        var loading: [Bool] = []
        playback.onScrubPreviewLoading = { loading.append($0) }

        playback.updateScrubPreview(0.2)
        playback.updateScrubPreview(0.6)
        // One fetch in flight: the second request only moves the target.
        #expect(loading == [true])

        await Self.settle { loading.last == false }
        // The first landed on 0.2 while 0.6 was wanted, so 0.6 was fetched,
        // and only then did the card stop waiting.
        #expect(loading == [true, true, false])
    }

    @Test func aNilRequestEndsTheWait() async {
        let (playback, _, _) = await Self.playingPage()
        var loading: [Bool] = []
        playback.onScrubPreviewLoading = { loading.append($0) }

        playback.updateScrubPreview(nil)

        #expect(loading == [false])
    }

    @Test func aFetchThatLandsAfterTheScrubEndedLeavesTheCardAlone() async {
        let (playback, _, _) = await Self.playingPage()
        var loading: [Bool] = []
        var pictures = 0
        playback.onScrubPreviewLoading = { loading.append($0) }
        playback.onScrubPreviewPicture = { _ in pictures += 1 }

        playback.updateScrubPreview(0.4)
        playback.updateScrubPreview(nil)
        // Every look the budget allows: the fetch lands within the first few.
        await Self.settle(until: { false })

        // The landing neither fetched again nor touched the card.
        #expect(loading == [true, false])
        #expect(pictures == 0)
    }
}
