import CoreModels
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Feed

// The first comments fly in with the post (#2002): one warm for every
// surface that opens a post, and the text stand-in drawing what it holds.

/// Records each prefetch; held ids answer `isHeld`; prefetches wait until
/// released, so what is in flight can be read.
@MainActor
private final class Recorder {
    var asked: [PostID] = []
    var held: Set<PostID> = []
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func prefetch(_ id: PostID) async {
        asked.append(id)
        await withCheckedContinuation { waiting.append($0) }
        held.insert(id)
    }

    func releaseAll() {
        let all = waiting
        waiting = []
        all.forEach { $0.resume() }
    }

    var waitingCount: Int { waiting.count }
}

@MainActor
private func makeWarm(_ recorder: Recorder) -> PostOpenWarm {
    PostOpenWarm(
        prefetch: { id in await recorder.prefetch(id) },
        isHeld: { recorder.held.contains($0) }
    )
}

@MainActor
private func settle(until condition: () -> Bool) async -> Bool {
    for _ in 0..<2_000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

private let ids = (0..<4).map { PostID("post-\($0)") }

@MainActor
struct PostOpenWarmTests {
    /// What is on screen is asked at once, in parallel, each once.
    @Test func whatIsOnScreenIsAskedAtOnceAndOnlyOnce() async {
        let recorder = Recorder()
        let warm = makeWarm(recorder)
        warm.warmNow(ids)
        warm.warmNow(ids) // the reconcile asks again at ~30 Hz
        #expect(await settle { recorder.waitingCount == 4 })
        #expect(Set(recorder.asked) == Set(ids))
        #expect(recorder.asked.count == 4)
        recorder.releaseAll()
        #expect(await settle { warm.debugInFlight.isEmpty })
        warm.warmNow(ids) // now held: nothing
        await Task.yield()
        #expect(recorder.asked.count == 4)
    }

    /// The queue asks one at a time, in order, and claims an id only when
    /// it reaches it: a post on screen jumps it.
    @Test func theQueueIsSerialAndAPostOnScreenJumpsIt() async {
        let recorder = Recorder()
        let warm = makeWarm(recorder)
        warm.warmLater(ids)
        #expect(await settle { recorder.waitingCount == 1 })
        #expect(recorder.asked == [ids[0]])
        warm.warmNow([ids[3]])
        #expect(await settle { recorder.waitingCount == 2 })
        #expect(recorder.asked == [ids[0], ids[3]])
        // Each answer lets the queue reach its next id: release as they come.
        #expect(await settle {
            recorder.releaseAll()
            return warm.debugQueued.isEmpty && warm.debugInFlight.isEmpty
        })
        #expect(recorder.asked == [ids[0], ids[3], ids[1], ids[2]], "asked twice, or out of order")
    }

    /// What a surface queued is dropped once it goes.
    @Test func aGoneSurfacesQueueIsDropped() async {
        let recorder = Recorder()
        let warm = makeWarm(recorder)
        var surface: NSObject? = NSObject()
        warm.warmLater([ids[0]])
        warm.warmLater([ids[1], ids[2]], owner: surface)
        #expect(await settle { recorder.waitingCount == 1 })
        surface = nil
        recorder.releaseAll()
        #expect(await settle { warm.debugQueued.isEmpty && warm.debugInFlight.isEmpty })
        #expect(recorder.asked == [ids[0]])
        _ = surface
    }

    /// ⚠️ ONE BATCH FIRST (#2003): what either queue claims is asked of the
    /// batch in one call, and only what it did not cover warms on its own.
    @Test func theBatchGoesFirstAndOnlyTheUncoveredWarmAlone() async {
        let recorder = Recorder()
        var batches: [[PostID]] = []
        let warm = PostOpenWarm(
            prefetch: { id in await recorder.prefetch(id) },
            isHeld: { recorder.held.contains($0) },
            previews: { @MainActor batch in
                batches.append(batch)
                let covered = Set(batch.filter { $0 != ids[2] })
                recorder.held.formUnion(covered)
                return covered
            }
        )
        warm.warmNow(ids)
        #expect(await settle { recorder.waitingCount == 1 })
        #expect(batches == [ids], "not one batch for the page")
        #expect(recorder.asked == [ids[2]], "a covered post warmed on its own")
        recorder.releaseAll()
        #expect(await settle { warm.debugInFlight.isEmpty })

        // The queue: one batch for what it holds, the same rule.
        let more = (4..<8).map { PostID("post-\($0)") }
        warm.warmLater(more)
        #expect(await settle { batches.count == 2 && warm.debugQueued.isEmpty && warm.debugInFlight.isEmpty })
        #expect(batches.last == more)
        #expect(recorder.asked == [ids[2]])
    }

    /// A post already held asks nothing, from either queue.
    @Test func aHeldPostAsksNothing() async {
        let recorder = Recorder()
        recorder.held = Set(ids)
        let warm = makeWarm(recorder)
        warm.warmNow(ids)
        warm.warmLater(ids)
        #expect(await settle { warm.debugQueued.isEmpty })
        #expect(recorder.asked.isEmpty)
    }
}

// MARK: - The text stand-in

private func comment(_ id: String, parent: String? = nil) -> CommentEntry {
    CommentEntry(
        id: id, authorID: ProfileID("prof-1"), authorName: "Ava", authorHandle: "ava",
        body: "Comment \(id)", createdAt: Date(timeIntervalSince1970: 1000), parentID: parent
    )
}

private func textModel(comments: Int64?) -> FeedItemDisplayModel {
    FeedItemDisplayModel(
        id: PostID("post-text"), authorID: ProfileID("prof-1"), authorName: "Ava", metaText: "@ava",
        avatarURL: nil, caption: "A text post", mediaURL: nil, mediaKind: .image, thumbnailURL: nil,
        audioText: nil, likeCount: 3, timestampText: "now",
        cardMetrics: comments.map { PostCardMetrics(reactions: 3, comments: $0) }
    )
}

@MainActor
struct RestingStandInHeldRowsTests {
    private func standIn(held: [CommentEntry], known: Int64?) -> RestingCommentsPlaceholderView {
        let view = RestingCommentsPlaceholderView(
            model: textModel(comments: known), imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), safeAreaTop: 59,
            heldComments: held
        )
        view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        view.layoutIfNeeded()
        return view
    }

    /// Held top-level comments are real rows, in order, replies left out;
    /// with every comment held, no bone.
    @Test func heldCommentsAreRowsAndNoBoneWhenAllAreHeld() {
        let view = standIn(held: [comment("a"), comment("r", parent: "a"), comment("b")], known: 2)
        #expect(view.debugHeldRowIDs == ["a", "b"])
        #expect(view.debugBoneCount == 0)
    }

    /// Bones stand only for what is not held yet.
    @Test func bonesOnlyForTheRest() {
        let view = standIn(held: [comment("a"), comment("b")], known: 5)
        #expect(view.debugHeldRowIDs == ["a", "b"])
        #expect(view.debugBoneCount == 3)
    }

    /// Nothing held: the bones, as before; a post known to have none: none.
    @Test func nothingHeldKeepsTheBones() {
        #expect(standIn(held: [], known: 4).debugBoneCount == 4)
        #expect(standIn(held: [], known: 0).debugBoneCount == 0)
        #expect(standIn(held: [], known: nil).debugBoneCount > 0)
    }
}

// MARK: - The seed and the load

private final class NoFeed: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { throw FeedError.transport(message: "unused") }
    func loadPage(afterToken token: String) async throws -> FeedPage { throw FeedError.transport(message: "unused") }
    func loadPost(_ id: PostID) async throws -> FeedEntry { throw FeedError.transport(message: "unused") }
}

/// The warm already holds the first page; the load answers the same page.
private final class WarmedComments: CommentsProviding, @unchecked Sendable {
    let page: [CommentEntry]
    init(_ page: [CommentEntry]) { self.page = page }
    func loadComments(for postID: PostID) async throws -> [CommentEntry] { page }
    func cachedTopComments(for postID: PostID) -> [CommentEntry]? { page }
    func addComment(
        _ body: String, to postID: PostID, parentID: String?, commentID: String
    ) async throws -> CommentEntry {
        throw CommentsError.transport(message: "unused")
    }
}

@MainActor
struct SeedKeepsTheFirstCueTests {
    /// The replica and the live page read the same seed, and the full load
    /// after it keeps the first cue: the comment the flight showed is the
    /// one the landed page shows.
    @Test func theLoadKeepsTheSeedsFirstCue() async {
        let sentences = (0..<5).map {
            CommentEntry(
                id: "s\($0)", authorID: ProfileID("prof-1"), authorName: "Ava", authorHandle: "ava",
                body: "This is a longer thought number \($0) worth reading.", createdAt: Date(timeIntervalSince1970: 1000)
            )
        }
        let viewModel = FeedViewModel(repository: NoFeed(), commentsProvider: WarmedComments(sentences))
        let id = PostID("post-0042")

        let seed = viewModel.commentStreams(for: id)
        #expect(!seed.isLoaded)
        let first = try? #require(seed.subtitles.first)
        #expect(viewModel.commentStreams(for: id).subtitles.first == first, "the replica and the page read different seeds")

        let loaded: FeedViewModel.CommentStreams = await withCheckedContinuation { continuation in
            viewModel.onCommentStreamsChange = { _, streams in
                viewModel.onCommentStreamsChange = nil
                continuation.resume(returning: streams)
            }
            viewModel.pageDidBecomeActive(id)
        }
        #expect(loaded.isLoaded)
        #expect(loaded.subtitles.first == first, "the hydration changed the cue on screen")
    }
}

// MARK: - The landing keeps the replica's pill

@MainActor
struct LandingKeepsTheWarmedPillTests {
    private let cues = (0..<3).map { SubtitleCue(id: "c\($0)", text: "A thought worth reading, number \($0).") }

    /// A page that owned its cues when it came on screen showed the first
    /// one instantly, as the replica did: the landing leaves it be.
    @Test func aWarmedPillIsNotReplayedAtTheLanding() {
        let zone = SnapSubtitleView()
        zone.setCues(cues)
        zone.setActive(true)
        #expect(zone.debugIsCycling)
        let cycle = zone.debugGeneration
        zone.replayEntrance()
        #expect(zone.debugGeneration == cycle, "the landing replayed a pill the flight already showed")
    }

    /// Cues that landed during the flight (a cold open) and whose entrance
    /// is over, unseen under the hidden chrome, enter again at the landing,
    /// with their fade.
    @Test func aColdPillEntersAtTheLanding() {
        let zone = SnapSubtitleView()
        var clock: CFTimeInterval = 100
        zone.now = { clock }
        zone.setActive(true)
        zone.setCues(cues)
        clock += SnapSubtitleView.leadInDelay + SnapSubtitleView.fadeDuration
        let cycle = zone.debugGeneration
        zone.replayEntrance()
        #expect(zone.debugGeneration > cycle)
        #expect(zone.debugIsCycling)
    }

    /// ⚠️ A COLD PILL STILL FADING IN AT THE LANDING FINISHES ITS ENTRANCE
    /// (#2002, the owner's device): restarting it blinked the pill — shown,
    /// gone, back after the lead-in.
    @Test func aColdPillStillEnteringIsNotRestartedAtTheLanding() {
        let zone = SnapSubtitleView()
        var clock: CFTimeInterval = 100
        zone.now = { clock }
        zone.setActive(true)
        zone.setCues(cues)
        // The device's trace: the landing 414 ms after the cues, mid-fade.
        clock += 0.414
        let cycle = zone.debugGeneration
        zone.replayEntrance()
        #expect(zone.debugGeneration == cycle, "the landing restarted an entrance still running")
        #expect(zone.debugIsCycling)
    }
}
