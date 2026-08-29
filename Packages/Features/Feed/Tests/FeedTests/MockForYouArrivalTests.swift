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

    /// Six, and all of them ahead of the clock — which is what makes them
    /// arrivals rather than just the top of the corpus.
    ///
    /// ⚠️ THE ONE PLACE THE COUNT IS A LITERAL. The tests below derive it, so
    /// a further arrival breaks exactly this one — deliberately, because
    /// "someone added a fixture" is worth being told about once and not five
    /// times. Six was the over-capacity gallery (`post-new-05`), staged first
    /// so the pool's limits are reachable without scrolling; seven and eight
    /// are the ADJACENT TEXT PAIR, staged ahead of it so a cold launch opens on
    /// a text page and the first page down is another one.
    @Test func eightPostsAreStagedAheadOfTheClock() {
        #expect(arrivals().count == 8)
    }

    /// ⚠️ AND TWO OF THEM ARE TEXT, NEXT TO EACH OTHER.
    ///
    /// The corpus makes every third post text-only, so two text posts are never
    /// adjacent in it — and "a text page arrives while another text page still
    /// owns the resting interface" is where three separate defects lived. It
    /// could not be reached from the seed at all; every recording of it was
    /// made by opening a post and paging until the order happened to oblige.
    @Test func theHeadOfTheFeedHasTwoTextPostsInARow() {
        let head = arrivals().suffix(2)

        #expect(head.count == 2)
        #expect(head.allSatisfy { $0.kind == .text },
                "the pair a cold launch opens on must both be text-only")
    }

    /// The unfiltered lens counts every one of them: the badge For You opens
    /// with.
    @Test func theUnfilteredLensCountsThemAll() {
        #expect(ContentContext.all.filtering(arrivals()).count == arrivals().count)
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
        // Counted rather than written down: this test is about the arrivals
        // being CONTIGUOUS at the front, and a literal here would fail for the
        // unrelated reason that the fixture grew.
        let staged = arrivals().count
        #expect(posts.prefix(staged).allSatisfy { $0.publishedAtMS > nowMS })
        #expect(posts.dropFirst(staged).allSatisfy { $0.publishedAtMS < nowMS })
    }

    /// Distinct ids in their own namespace, so they cannot collide with the
    /// `post-NNNN` corpus that other fixtures address by index.
    @Test func theArrivalsHaveTheirOwnIDs() {
        let staged = arrivals().count
        let ids = MockSocialDataset().posts.prefix(staged).map(\.postID)
        #expect(Set(ids).count == staged)
        #expect(ids.allSatisfy { $0.hasPrefix("post-new-") })
    }
}
