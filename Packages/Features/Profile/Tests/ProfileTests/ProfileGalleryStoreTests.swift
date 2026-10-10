import CoreModels
import CoreNetworking
import Foundation
import PostGrid
import Testing
@testable import Profile

// The gallery's source of truth on its own (#846): no view model, no fetch.

private func post(_ id: String, _ kind: GalleryPost.Kind = .photo, at ms: Int64) -> GalleryPost {
    GalleryPost(id: PostID(id), kind: kind, isRepost: false, thumbnailURL: nil, caption: id, publishedAtMS: ms)
}

private func repost(_ id: String, at ms: Int64) -> GalleryPost {
    GalleryPost(id: PostID(id), kind: .photo, isRepost: true, thumbnailURL: nil, caption: id, publishedAtMS: ms)
}

private func page(_ posts: [GalleryPost], next: String? = nil) -> GalleryPage {
    GalleryPage(posts: posts, nextPageToken: next)
}

private let offline = ProfileError.transport(message: "x", failure: .offline)
private let timedOut = ProfileError.transport(message: "x", failure: .timeout)
private struct Refusal: Error {}

@MainActor
private func loadedStore(
    authored: GalleryPage = page([]), tagged: GalleryPage = page([])
) -> ProfileGalleryStore {
    let store = ProfileGalleryStore()
    store.applyFirstPages(authored: authored, authoredFailure: nil, tagged: tagged, taggedFailure: nil)
    return store
}

@MainActor
struct ProfileGalleryStoreTests {
    // MARK: Filtering per source

    @Test func postsRepostsAndTaggedEachReadTheirOwnSlice() {
        let store = loadedStore(
            authored: page([post("p1", at: 30), repost("r1", at: 20), post("t1", .text, at: 10)]),
            tagged: page([post("g1", at: 25)])
        )
        #expect(store.tiles(.activity, source: .posts).map(\.id.rawValue) == ["p1", "t1"])
        #expect(store.tiles(.activity, source: .reposts).map(\.id.rawValue) == ["r1"])
        #expect(store.tiles(.activity, source: .tagged).map(\.id.rawValue) == ["g1"])
        #expect(store.tiles(.activity, source: .all).map(\.id.rawValue) == ["p1", "g1", "r1", "t1"])
        #expect(store.tiles(.media, source: .posts).map(\.id.rawValue) == ["p1"])
        #expect(store.tiles(.short, source: .posts).map(\.id.rawValue) == ["t1"])
    }

    @Test func theSnapshotGivesEachPageItsSourceAndItsEmptyLine() {
        let store = loadedStore(authored: page([post("p1", at: 30)]))
        let snapshot = store.snapshot(isOwnProfile: false)
        #expect(snapshot.activity == .content([post("p1", at: 30)]))
        #expect(snapshot.reposts == .empty(message: ""))
        #expect(snapshot.tagged == .empty(message: ""))
        #expect(snapshot.saved == .empty(message: ""))
        #expect(snapshot.isComplete && snapshot.repostsComplete && snapshot.taggedComplete)
    }

    @Test func anEmptyPostsPageSaysPostsWillAppear() {
        let snapshot = loadedStore().snapshot(isOwnProfile: true)
        #expect(snapshot.activity == .empty(message: "Posts will appear here."))
        #expect(snapshot.media == .empty(message: "No media in posts yet."))
    }

    @Test func savedIsShownOnlyOnYourOwnProfile() {
        let store = loadedStore()
        store.saved = .content([post("s1", at: 1)])
        #expect(store.snapshot(isOwnProfile: true).saved == .content([post("s1", at: 1)]))
        #expect(store.snapshot(isOwnProfile: false).saved == .empty(message: ""))
    }

    @Test func everyPageLoadsUntilItsFirstPageAnswers() {
        let snapshot = ProfileGalleryStore().snapshot(isOwnProfile: false)
        #expect(snapshot.activity == .loading)
        #expect(snapshot.reposts == .loading)
        #expect(snapshot.tagged == .loading)
    }

    // MARK: Paging

    @Test func aNextPageAppendsBelowAndDropsWhatIsAlreadyShown() {
        let store = loadedStore(authored: page([post("a", at: 30), post("b", at: 20)], next: "t2"))
        #expect(store.tokensToFollow() == ("t2", nil))
        let failed = store.applyNextPages(
            tokens: ("t2", nil),
            authored: .success(page([post("b", at: 20), post("c", at: 10)])),
            tagged: nil
        )
        #expect(!failed)
        #expect(store.tiles(.activity).map(\.id.rawValue) == ["a", "b", "c"])
        #expect(store.authoredHasLaterPages)
        #expect(store.isComplete())
    }

    @Test func aPageThatBringsNothingNewLeavesTheCorpusAsItWas() {
        let store = loadedStore(authored: page([post("a", at: 30)], next: "t2"))
        store.applyNextPages(tokens: ("t2", nil), authored: .success(page([post("a", at: 30)])), tagged: nil)
        #expect(store.authored == [post("a", at: 30)])
        #expect(!store.authoredHasLaterPages)
        #expect(store.authoredToken == nil)
    }

    @Test func aPageForAStaleTokenIsIgnored() {
        let store = loadedStore(authored: page([post("a", at: 30)], next: "t2"))
        store.applyNextPages(tokens: ("old", nil), authored: .success(page([post("z", at: 5)])), tagged: nil)
        #expect(store.tiles(.activity).map(\.id.rawValue) == ["a"])
        #expect(store.authoredToken == "t2")
    }

    @Test func aRevalidationMergesItsFirstPageOverLaterPages() {
        let store = loadedStore(authored: page([post("x", at: 35), post("a", at: 30)], next: "t2"))
        store.applyNextPages(tokens: ("t2", nil), authored: .success(page([post("c", at: 10)])), tagged: nil)
        store.applyFirstPages(
            authored: page([post("new", at: 40), post("a", at: 30)], next: "t2'"), authoredFailure: nil,
            tagged: page([]), taggedFailure: nil
        )
        // "x" went away (newer than the fresh page's oldest), "c" is older: kept.
        #expect(store.tiles(.activity).map(\.id.rawValue) == ["new", "a", "c"])
        // The deeper corpus keeps its own token.
        #expect(store.authoredToken == nil)
    }

    @Test func allStopsAtTheFrontierOfAnUnfinishedCorpus() {
        let store = loadedStore(
            authored: page([post("a", at: 30), post("b", at: 10)]),
            tagged: page([post("g", at: 20)], next: "g2")
        )
        #expect(store.tiles(.activity, source: .all).map(\.id.rawValue) == ["a", "g"])
    }

    // MARK: Failures

    @Test func aFailedFirstPageFailsOnlyThePagesThatReadIt() {
        let store = ProfileGalleryStore()
        store.applyFirstPages(
            authored: page([post("a", at: 1)]), authoredFailure: nil,
            tagged: nil, taggedFailure: .offline
        )
        let snapshot = store.snapshot(isOwnProfile: false)
        #expect(snapshot.activity == .content([post("a", at: 1)]))
        #expect(snapshot.tagged == .failed(message: FailureCopy.offline))
        #expect(store.page(.activity, .all) == .failed(message: FailureCopy.offline))
    }

    @Test func aFirstPageFailureNotFromTheNetworkOffersThePull() {
        let store = ProfileGalleryStore()
        store.applyFirstPages(authored: nil, authoredFailure: nil, tagged: page([]), taggedFailure: nil)
        #expect(store.page(.activity, .posts) == .failed(message: "Couldn't load. Pull to retry."))
    }

    @Test func aFailedNextPagePausesPagingAndNamesTheCauseOnAnEmptyTab() {
        let store = loadedStore(authored: page([post("t", .text, at: 30)], next: "t2"))
        #expect(store.page(.media, .posts) == .loading)
        let failed = store.applyNextPages(tokens: ("t2", nil), authored: .failure(offline), tagged: nil)
        #expect(failed)
        #expect(store.isPausedByFailure)
        #expect(store.page(.media, .posts) == .failed(message: FailureCopy.offline))
        store.resumePaging()
        #expect(!store.isPausedByFailure)
        #expect(store.page(.media, .posts) == .loading)
    }

    @Test func offlineOutranksATimeoutWhenBothCorporaFail() {
        let store = loadedStore(authored: page([], next: "a2"), tagged: page([], next: "g2"))
        store.pageSource = .all
        store.applyNextPages(tokens: ("a2", "g2"), authored: .failure(timedOut), tagged: .failure(offline))
        #expect(store.moreFailure == .offline)
        #expect(ProfileGalleryStore.likelierCause(.timeout, .server(code: "x")) == .timeout)
        #expect(ProfileGalleryStore.likelierCause(nil, .refused(code: "y")) == .refused(code: "y"))
    }

    @Test func aMissingAnswerForAnAskedTokenCountsAsAFailure() {
        let store = loadedStore(authored: page([], next: "a2"))
        #expect(store.applyNextPages(tokens: ("a2", nil), authored: nil, tagged: nil))
        #expect(store.moreFailure == nil)
        #expect(store.isPausedByFailure)
    }

    @Test func aResetForgetsEveryCorpusAndGoesBackToPosts() {
        let store = loadedStore(authored: page([post("a", at: 1)], next: "a2"))
        store.pageSource = .tagged
        store.reset()
        #expect(store.pageSource == .posts)
        #expect(store.authored == nil && store.tagged == nil)
        #expect(store.tokensToFollow(.all) == (nil, nil))
        #expect(store.page(.activity, .posts) == .loading)
    }

    // MARK: Source switch

    @Test func aSourceSwitchMovesTheMediaPageAndThePagingTokens() {
        let store = loadedStore(
            authored: page([post("p", at: 30), repost("r", at: 20)], next: "a2"),
            tagged: page([post("g", at: 25)], next: "g2")
        )
        #expect(store.tokensToFollow() == ("a2", nil))
        #expect(store.snapshot(isOwnProfile: false).media == .content([post("p", at: 30)]))

        store.pageSource = .tagged
        #expect(store.tokensToFollow() == (nil, "g2"))
        #expect(store.snapshot(isOwnProfile: false).media == .content([post("g", at: 25)]))

        store.pageSource = .reposts
        #expect(store.tokensToFollow() == ("a2", nil))
        #expect(store.snapshot(isOwnProfile: false).media == .content([repost("r", at: 20)]))
    }

    // MARK: Memoization

    @Test func aRenderFiltersEachCombinationOnce() {
        let store = loadedStore(authored: page([post("p", at: 30), repost("r", at: 20)]))
        _ = store.snapshot(isOwnProfile: false)
        let firstRender = store.tileComputations
        _ = store.snapshot(isOwnProfile: false)
        _ = store.tiles(.activity, source: .posts)
        #expect(store.tileComputations == firstRender)
    }

    @Test func anyCorpusChangeDropsTheMemo() {
        let store = loadedStore(authored: page([post("p", at: 30)], next: "a2"))
        #expect(store.tiles(.activity).count == 1)
        store.applyNextPages(tokens: ("a2", nil), authored: .success(page([post("q", at: 20)])), tagged: nil)
        #expect(store.tiles(.activity).map(\.id.rawValue) == ["p", "q"])
        store.removeAuthoredPost(PostID("p"))
        #expect(store.tiles(.activity).map(\.id.rawValue) == ["q"])
    }
}
