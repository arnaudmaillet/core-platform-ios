import CoreModels
import Foundation
import Testing
@testable import Search

private func post(
    _ id: String,
    reactions: Int64? = nil,
    publishedAtMS: Int64 = 0,
    authorID: String = "author",
    authorName: String = "Author",
    authorHandle: String = "author"
) -> ExplorePost {
    ExplorePost(
        id: id,
        authorID: ProfileID(authorID),
        authorName: authorName,
        authorHandle: authorHandle,
        reactionCount: reactions,
        publishedAtMS: publishedAtMS
    )
}

struct ExploreRankingTests {
    // MARK: - Ranking order

    @Test func mostReactedComesFirst() {
        let ranked = ExploreRanking.ranked([
            post("a", reactions: 3), post("b", reactions: 40), post("c", reactions: 12)
        ])

        #expect(ranked.map(\.id) == ["b", "c", "a"])
    }

    /// A post the read-model had no counter for is not "zero reactions plus a
    /// guess" — it sorts as zero and stays at the bottom rather than jumping
    /// the queue.
    @Test func anAbsentCounterSortsAsZero() {
        let ranked = ExploreRanking.ranked([post("a"), post("b", reactions: 1)])

        #expect(ranked.map(\.id) == ["b", "a"])
    }

    @Test func equalReactionsBreakOnRecency() {
        let ranked = ExploreRanking.ranked([
            post("old", reactions: 5, publishedAtMS: 100),
            post("new", reactions: 5, publishedAtMS: 900)
        ])

        #expect(ranked.map(\.id) == ["new", "old"])
    }

    /// `sorted(by:)` is not guaranteed stable, so without a total order a
    /// re-fetch could reshuffle rows the viewer is already looking at.
    @Test func fullyTiedPostsStillHaveOneOrder() {
        let posts = [post("b", reactions: 5), post("a", reactions: 5), post("c", reactions: 5)]

        #expect(ExploreRanking.ranked(posts).map(\.id) == ["c", "b", "a"])
        #expect(
            ExploreRanking.ranked(posts.reversed()).map(\.id)
                == ExploreRanking.ranked(posts).map(\.id)
        )
    }

    @Test func rankingAnEmptyCorpusIsEmpty() {
        #expect(ExploreRanking.ranked([]).isEmpty)
    }

    // MARK: - Creators

    @Test func creatorsFollowTheRankedOrderAndDeduplicate() {
        let ranked = ExploreRanking.ranked([
            post("a", reactions: 9, authorID: "p1", authorName: "Ada", authorHandle: "ada"),
            post("b", reactions: 5, authorID: "p2", authorName: "Grace", authorHandle: "grace"),
            post("c", reactions: 1, authorID: "p1", authorName: "Ada", authorHandle: "ada")
        ])

        let creators = ExploreRanking.creators(from: ranked, limit: 10)

        #expect(creators.map(\.id) == [ProfileID("p1"), ProfileID("p2")])
        #expect(creators.map(\.monogram) == ["A", "G"])
    }

    @Test func creatorsAreCapped() {
        let ranked = (0..<10).map {
            post("p\($0)", reactions: Int64(10 - $0), authorID: "a\($0)", authorName: "N\($0)", authorHandle: "h\($0)")
        }

        #expect(ExploreRanking.creators(from: ranked, limit: 3).count == 3)
    }

    @Test func aBlankDisplayNameFallsBackToTheHandle() {
        let ranked = [post("a", reactions: 1, authorID: "p1", authorName: "   ", authorHandle: "ada")]

        let creators = ExploreRanking.creators(from: ranked, limit: 10)

        #expect(creators.map(\.displayName) == ["ada"])
        #expect(creators.map(\.monogram) == ["A"])
    }

    /// Nothing to render and nothing to route to — an author with neither a
    /// name nor a handle is not a row.
    @Test func anAuthorWithNoNameAtAllIsSkipped() {
        let ranked = [post("a", reactions: 1, authorID: "p1", authorName: "", authorHandle: "")]

        #expect(ExploreRanking.creators(from: ranked, limit: 10).isEmpty)
    }
}
