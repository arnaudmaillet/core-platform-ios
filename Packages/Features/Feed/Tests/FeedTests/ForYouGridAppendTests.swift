import CoreModels
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
}
