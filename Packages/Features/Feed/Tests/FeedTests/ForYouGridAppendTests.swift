import CoreModels
import Foundation
import PostGrid
import Testing
@testable import Feed

/// A page landing must be expressed as an insert, not a reload: `reloadData`
/// recycles every realized cell, which tears down the players under the tiles
/// the viewer is currently watching. Observed as all four playing tiles
/// stopping and restarting inside 60ms during a drag.
/// `@MainActor` because `ForYouGridPage` is a `UIView` and so is main-actor
/// isolated, statics included. Without it these bodies call across isolation
/// and trap whenever the runner happens to schedule them off the main thread —
/// which is why every test here passed alone and the suite crashed in parallel,
/// taking unrelated suites down with it and still reporting "passed" on a
/// partial count.
@MainActor
struct ForYouGridAppendTests {
    private func post(_ id: String) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: .photo, isRepost: false, thumbnailURL: nil,
            caption: "", publishedAtMS: 0
        )
    }

    @Test func aPureAppendReportsTheNewPosts() {
        let old = [post("a"), post("b")]
        let new = old + [post("c"), post("d")]
        #expect(ForYouGridPage.addedPosts(from: old, to: new)?.map(\.id.rawValue) == ["c", "d"])
    }

    @Test func anUnchangedListIsNotAnAppend() {
        let same = [post("a"), post("b")]
        #expect(ForYouGridPage.addedPosts(from: same, to: same) == nil)
    }

    /// A re-rank that only ADDS is an addition. Trending re-ranks the corpus on
    /// every page, and demanding an unchanged prefix meant each landing took the
    /// reload branch and re-permuted every slot — the grid reshuffling under the
    /// viewer, which reads as tiles disappearing. The newcomers are what gets
    /// placed; the upstream order of posts already on screen is ignored, exactly
    /// as the layout's immutable slices already promise.
    @Test func aReorderThatOnlyAddsIsAnAddition() {
        let old = [post("a"), post("b")]
        let reordered = [post("b"), post("a"), post("c")]
        #expect(ForYouGridPage.addedPosts(from: old, to: reordered)?.map(\.id.rawValue) == ["c"])
    }

    /// An in-place edit rides along: membership is unchanged, so the newcomer is
    /// still the only thing inserted and the edited post keeps its slot.
    @Test func anInPlaceEditDoesNotForceAReload() {
        let old = [post("a"), post("b")]
        var edited = old
        edited[0].reactionCount = 5
        #expect(ForYouGridPage.addedPosts(from: old, to: edited + [post("c")])?
            .map(\.id.rawValue) == ["c"])
    }

    /// A post that vanished is a removal, and no insert can express it.
    @Test func aReplacementIsNotAnAddition() {
        let old = [post("a"), post("b")]
        #expect(ForYouGridPage.addedPosts(from: old, to: [post("a"), post("c"), post("d")]) == nil)
    }

    @Test func aShrinkingListIsNotAnAppend() {
        let old = [post("a"), post("b"), post("c")]
        #expect(ForYouGridPage.addedPosts(from: old, to: [post("a")]) == nil)
    }

    /// First content arriving is a reload, not an insert — there is nothing to
    /// preserve, and the skeleton cross-dissolve owns that transition.
    @Test func fillingAnEmptyListIsNotAnAppend() {
        #expect(ForYouGridPage.addedPosts(from: [], to: [post("a")]) == nil)
    }

    /// ⚠️ **Widening a lens has the exact shape of an append and is not one.**
    /// Every Work post is still present plus thirty more, so `addedPosts`
    /// reports them — correctly, by its own rule, which is about MEMBERSHIP so
    /// that a Trending re-rank still counts as an addition. The newcomers
    /// belong all through the list rather than after it, and inserting them at
    /// the end mis-orders the timeline; when the sectioning moves in the same
    /// pass, `performBatchUpdates` throws and takes the app down.
    ///
    /// So the shape alone cannot decide it, and this test says so rather than
    /// pretending otherwise. The page is TOLD, by `onCorpusReset` — see
    /// `ForYouCorpusResetTests`.
    @Test func aWidenedLensLooksExactlyLikeAnAppend() {
        let narrow = [post("w1"), post("w2")]
        let wide = [post("a"), post("w1"), post("b"), post("w2"), post("c")]
        #expect(ForYouGridPage.addedPosts(from: narrow, to: wide) != nil)
    }
}

private final class ResetStubProvider: ForYouProviding, @unchecked Sendable {
    let posts: [GalleryPost]
    init(posts: [GalleryPost]) { self.posts = posts }
    func firstPage() async throws -> ForYouPage {
        ForYouPage(posts: posts, nextPageToken: "next")
    }
    func page(after token: String) async throws -> ForYouPage {
        ForYouPage(posts: [], nextPageToken: nil)
    }
}

private func settleReset() async {
    for _ in 0..<12 { await Task.yield() }
}

/// The signal that stops a re-derived corpus being mistaken for an extended one.
@MainActor
struct ForYouCorpusResetTests {
    private func page(_ id: String, caption: String) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: .photo, isRepost: false, thumbnailURL: nil,
            caption: caption, publishedAtMS: 0
        )
    }

    private func makeModel() -> ForYouViewModel {
        ForYouViewModel(
            repository: ResetStubProvider(posts: [
                page("w", caption: "office deadline"),
                page("g", caption: "boss level speedrun")
            ]),
            preferences: nil,
            unreadStore: ForYouUnreadStore(
                defaults: UserDefaults(suiteName: "foryou.reset.tests.\(UUID().uuidString)")!,
                keyPrefix: "test.reset",
                arguments: []
            )
        )
    }

    /// A lens change announces itself BEFORE the content it changes, so the
    /// pages have already dropped their incremental path by the time the new
    /// corpus arrives.
    @Test func changingTheLensAnnouncesAResetFirst() async {
        let model = makeModel()
        var events: [String] = []
        model.onCorpusReset = { events.append("reset") }
        model.onSnapshotChange = { _ in events.append("snapshot") }
        model.viewDidLoad()
        await settleReset()
        events.removeAll()

        model.setContext(.work)
        #expect(events.first == "reset")
        #expect(events.contains("snapshot"))
    }

    /// Re-ordering re-derives the corpus too — same rule, same announcement.
    @Test func changingTheOrderingAnnouncesAReset() async {
        let model = makeModel()
        model.viewDidLoad()
        await settleReset()
        var resets = 0
        model.onCorpusReset = { resets += 1 }
        model.setSource(.recent)
        #expect(resets == 1)
    }

    /// A page LANDING is a genuine extension and must not reset — that is the
    /// whole reason the incremental path exists, and resetting here would put
    /// the mosaic's reshuffle back.
    @Test func aPageLandingIsNotAReset() async {
        let model = makeModel()
        model.viewDidLoad()
        await settleReset()
        var resets = 0
        model.onCorpusReset = { resets += 1 }
        model.loadNextPageIfNeeded()
        await settleReset()
        #expect(resets == 0)
    }

    /// Choosing the lens already selected changes nothing, so it announces
    /// nothing — a reset would reload both pages for a tap that did nothing.
    @Test func reselectingTheSameLensAnnouncesNothing() async {
        let model = makeModel()
        model.viewDidLoad()
        await settleReset()
        var resets = 0
        model.onCorpusReset = { resets += 1 }
        model.setContext(.all)
        #expect(resets == 0)
    }
}
