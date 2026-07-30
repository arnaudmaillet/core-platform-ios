import CoreModels
import PostGrid
import Testing
@testable import Feed

/// A page landing must be expressed as an insert, not a reload: `reloadData`
/// recycles every realized cell, which tears down the players under the tiles
/// the viewer is currently watching. Observed as all four playing tiles
/// stopping and restarting inside 60ms during a drag.
struct ForYouGridAppendTests {
    private func post(_ id: String) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: .photo, isRepost: false, thumbnailURL: nil,
            caption: "", publishedAtMS: 0
        )
    }

    @Test func aPureAppendReportsTheNewIndices() {
        let old = [post("a"), post("b")]
        let new = old + [post("c"), post("d")]
        #expect(ForYouGridPage.appendedRange(from: old, to: new) == 2..<4)
    }

    @Test func anUnchangedListIsNotAnAppend() {
        let same = [post("a"), post("b")]
        #expect(ForYouGridPage.appendedRange(from: same, to: same) == nil)
    }

    /// Re-sorting (the discovery source switching between Trending and Recent)
    /// must fall back to a reload, or cells keep rendering the wrong posts.
    @Test func aReorderIsNotAnAppend() {
        let old = [post("a"), post("b")]
        let reordered = [post("b"), post("a"), post("c")]
        #expect(ForYouGridPage.appendedRange(from: old, to: reordered) == nil)
    }

    @Test func anInPlaceEditIsNotAnAppend() {
        let old = [post("a"), post("b")]
        var edited = old
        edited[0].reactionCount = 5
        #expect(ForYouGridPage.appendedRange(from: old, to: edited + [post("c")]) == nil)
    }

    @Test func aShrinkingListIsNotAnAppend() {
        let old = [post("a"), post("b"), post("c")]
        #expect(ForYouGridPage.appendedRange(from: old, to: [post("a")]) == nil)
    }

    /// First content arriving is a reload, not an insert — there is nothing to
    /// preserve, and the skeleton cross-dissolve owns that transition.
    @Test func fillingAnEmptyListIsNotAnAppend() {
        #expect(ForYouGridPage.appendedRange(from: [], to: [post("a")]) == nil)
    }
}
