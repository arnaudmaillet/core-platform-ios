import CoreModels
import CoreNetworkingMocks
import Foundation
import PostGrid
import Testing
@testable import Feed

/// The mock's staged arrivals, and the per-mode counts their captions produce.
///
/// These numbers reach the screen — the tab badge, the pill beside each row of
/// the context menu, the bottom bar item — so they are pinned here rather than
/// left to whoever next edits a caption. `ContentContext` is a keyword search
/// over captions (see its own note on why), which makes the wording of a
/// fixture load-bearing in a way that is very easy to miss: adding the word
/// "review" to the Focus arrival would silently move it into Work and change
/// two badges.
@MainActor
struct MockForYouArrivalTests {
    /// Rebuilt per test: the arrivals are stamped relative to the clock at
    /// construction, so a shared instance would age between cases.
    private func arrivals() -> [GalleryPost] {
        let dataset = MockSocialDataset()
        let nowMS = Int64(Date().timeIntervalSince1970 * 1000)
        return dataset.posts
            .filter { $0.publishedAtMS > nowMS }
            .map {
                GalleryPost(
                    id: PostID($0.postID),
                    kind: $0.media == nil ? .text : .photo,
                    isRepost: false,
                    thumbnailURL: nil,
                    caption: $0.caption,
                    publishedAtMS: $0.publishedAtMS,
                    reactionCount: nil
                )
            }
    }

    /// Five, and all of them ahead of the clock — which is what makes them
    /// arrivals rather than just the top of the corpus.
    @Test func fivePostsAreStagedAheadOfTheClock() {
        #expect(arrivals().count == 5)
    }

    /// The unfiltered lens counts every one of them: the badge For You opens
    /// with.
    @Test func theUnfilteredLensCountsAllFive() {
        #expect(ContentContext.all.filtering(arrivals()).count == 5)
    }

    @Test func workCountsThree() {
        #expect(ContentContext.work.filtering(arrivals()).count == 3)
    }

    @Test func focusCountsOne() {
        #expect(ContentContext.focus.filtering(arrivals()).count == 1)
    }

    /// Not every mode has news, and the menu says so with an empty slot rather
    /// than a zero pill. A fixture that accidentally matched every lens would
    /// make that case unreachable.
    @Test func someLensesHaveNothingNew() {
        #expect(ContentContext.gaming.filtering(arrivals()).isEmpty)
        #expect(ContentContext.entertainment.filtering(arrivals()).isEmpty)
    }

    /// They lead the timeline, so the Following list's "New" section is its
    /// first rows rather than a run somewhere in the middle.
    @Test func theArrivalsLeadTheCorpus() {
        let posts = MockSocialDataset().posts
        let nowMS = Int64(Date().timeIntervalSince1970 * 1000)
        #expect(posts.prefix(5).allSatisfy { $0.publishedAtMS > nowMS })
        #expect(posts.dropFirst(5).allSatisfy { $0.publishedAtMS < nowMS })
    }

    /// Distinct ids in their own namespace, so they cannot collide with the
    /// `post-NNNN` corpus that other fixtures address by index.
    @Test func theArrivalsHaveTheirOwnIDs() {
        let ids = MockSocialDataset().posts.prefix(5).map(\.postID)
        #expect(Set(ids).count == 5)
        #expect(ids.allSatisfy { $0.hasPrefix("post-new-") })
    }
}
