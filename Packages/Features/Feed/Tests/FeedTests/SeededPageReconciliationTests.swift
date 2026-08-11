import CoreModels
import MediaCore
import Testing
@testable import Feed

/// A SEED IS A FIRST DRAFT, NOT THE PAGE.
///
/// A post opened from a grid renders twice from one id: the projection the grid
/// hands over, then the entry the network returns. The data source is keyed by
/// id, so the second render is invisible to it — and the page keeps its draft
/// forever unless something says otherwise.
struct SeededPageReconciliationTests {
    private func model(
        _ id: String,
        author: String = "",
        meta: String = "",
        likes: Int64 = 0
    ) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id),
            authorID: ProfileID("a"),
            authorName: author,
            metaText: meta,
            avatarURL: nil,
            caption: "caption",
            mediaURL: nil,
            mediaKind: .image,
            thumbnailURL: nil,
            audioText: nil,
            likeCount: likes
        )
    }

    /// The case the whole type exists for: same post, better content.
    @Test func aSeededPageIsReconfiguredWhenTheRealEntryLands() {
        let seed = [PostID("p1"): model("p1", meta: "75d")]
        let real = [PostID("p1"): model("p1", author: "Demo Viewer", meta: "@you · 75d")]

        let changed = SeededPageReconciliation.idsNeedingReconfigure(
            ordered: [PostID("p1")], previous: seed, current: real, engaged: nil
        )

        #expect(changed == [PostID("p1")],
                "the page would keep its anonymous author capsule for its whole life")
    }

    /// …and only then. A render that changes nothing must not rebuild cells:
    /// this runs on every state emission, including engagement and comment
    /// updates that have their own targeted paths.
    @Test func anUnchangedPageIsLeftAlone() {
        let models = [PostID("p1"): model("p1", author: "Demo Viewer")]

        let changed = SeededPageReconciliation.idsNeedingReconfigure(
            ordered: [PostID("p1")], previous: models, current: models, engaged: nil
        )

        #expect(changed.isEmpty)
    }

    /// Reconfiguring rebuilds a cell, and the engaged one is hosting a child
    /// controller and a live comment stream.
    @Test func theEngagedPageIsNeverRebuiltUnderTheViewer() {
        let before = [PostID("p1"): model("p1"), PostID("p2"): model("p2")]
        let after = [
            PostID("p1"): model("p1", author: "Changed"),
            PostID("p2"): model("p2", author: "Changed")
        ]

        let changed = SeededPageReconciliation.idsNeedingReconfigure(
            ordered: [PostID("p1"), PostID("p2")],
            previous: before, current: after, engaged: PostID("p1")
        )

        #expect(changed == [PostID("p2")])
    }

    /// Inserts and removals are diffable's own job; claiming them here would
    /// reconfigure a cell that is being created or destroyed in the same apply.
    @Test func arrivalsAndDeparturesAreLeftToTheSnapshot() {
        let before = [PostID("gone"): model("gone")]
        let after = [PostID("new"): model("new")]

        let changed = SeededPageReconciliation.idsNeedingReconfigure(
            ordered: [PostID("new")], previous: before, current: after, engaged: nil
        )

        #expect(changed.isEmpty)
    }

    /// The result is in RENDER order, not dictionary order — a snapshot's
    /// reconfigure list should read the way the page does, and dictionary
    /// iteration order is not stable across runs.
    @Test func theAnswerFollowsTheOrderOnScreen() {
        let ordered = [PostID("a"), PostID("b"), PostID("c")]
        let before = Dictionary(uniqueKeysWithValues: ordered.map { ($0, model($0.rawValue)) })
        let after = Dictionary(
            uniqueKeysWithValues: ordered.map { ($0, model($0.rawValue, author: "x")) }
        )

        let changed = SeededPageReconciliation.idsNeedingReconfigure(
            ordered: ordered, previous: before, current: after, engaged: nil
        )

        #expect(changed == ordered)
    }

    /// A count arriving from `counter.v1` is a content change like any other.
    /// Named because it is the case that outlives the seeding story: the
    /// projection carries the grid's count and the entry carries the feed's.
    @Test func aChangedCountAloneIsEnough() {
        let before = [PostID("p1"): model("p1", author: "Same", likes: 0)]
        let after = [PostID("p1"): model("p1", author: "Same", likes: 42)]

        let changed = SeededPageReconciliation.idsNeedingReconfigure(
            ordered: [PostID("p1")], previous: before, current: after, engaged: nil
        )

        #expect(changed == [PostID("p1")])
    }
}
