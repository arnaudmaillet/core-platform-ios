import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Feed

private struct PreviewSession: AuthSessionProviding {
    func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
    func stateUpdates() async -> AsyncStream<AuthState> {
        AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
    }
    func logout() async {}
}

/// A page of tiles' first comments in one call (#2003): `ListPreviews`,
/// held as seeds beside the warmed first pages.
struct CommentPreviewsTests {
    private let dataset = MockSocialDataset()
    private let bff = MockBFF()

    init() {
        MockSocialServices(dataset: dataset).register(on: bff)
        MockCommentService(dataset: dataset).register(on: bff)
    }

    private func makeRepository() -> CommentsRepository {
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return CommentsRepository(
            commentClient: Comment_V1_CommentServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: PreviewSession()
        )
    }

    private func calls(to rpc: String) -> Int {
        bff.recordedRequests.filter { $0.path == "/comment.v1.CommentService/\(rpc)" }.count
    }

    private var pageOfTiles: [PostID] { dataset.posts.prefix(24).map { PostID($0.postID) } }

    /// One call for a page of tiles, none per tile, and every post covered.
    @Test func aPageOfTilesIsOneCall() async {
        let repository = makeRepository()
        let page = pageOfTiles
        let covered = await repository.prefetchPreviews(for: page)
        #expect(!covered.isEmpty)
        #expect(calls(to: "ListPreviews") == 1)
        #expect(calls(to: "ListTopLevel") == 0, "a tile asked on its own")
        for id in page { #expect(repository.holdsComments(for: id) == covered.contains(id)) }
        // Asked again: only what the first call could not decide, in one call.
        let again = await repository.prefetchPreviews(for: page)
        #expect(again.isDisjoint(with: covered))
        #expect(calls(to: "ListPreviews") == (covered.count == page.count ? 1 : 2))
    }

    /// A preview is a seed: `cachedTopComments` answers with it while no
    /// page is held, never with an empty one ("no comments" is a page's to
    /// say), and the first page replaces it.
    @Test func aPreviewIsASeedNotAPage() async throws {
        let repository = makeRepository()
        let page = pageOfTiles
        let covered = await repository.prefetchPreviews(for: page)
        for id in page where covered.contains(id) {
            let full = try await makeRepository().loadComments(for: id)
            if full.isEmpty {
                #expect(repository.cachedTopComments(for: id) == nil, "\(id.rawValue): an empty preview said 'no comments'")
            } else {
                let seed = try #require(repository.cachedTopComments(for: id))
                #expect(seed.count <= Int(CommentsRepository.previewLimit))
                #expect(seed.map(\.id) == Array(full.filter { $0.parentID == nil }.prefix(seed.count)).map(\.id),
                        "\(id.rawValue): the preview is not the page's prefix")
            }
        }
        let opened = try #require(page.first { repository.cachedTopComments(for: $0) != nil })
        let loaded = try await repository.loadComments(for: opened)
        #expect(repository.cachedTopComments(for: opened)?.map(\.id) == loaded.map(\.id), "the page did not replace the seed")
    }

    /// The previews were filtered for one viewer: a change wipes them.
    @Test func aViewerChangeWipesThePreviews() async {
        let repository = makeRepository()
        let page = pageOfTiles
        _ = await repository.prefetchPreviews(for: page)
        await repository.viewerDidChange(.member(AccountID("acct-2"), activeProfile: ProfileID("prof-2")))
        for id in page { #expect(!repository.holdsComments(for: id)) }
    }

    /// ⚠️ THE FIRST CUE STAYS THE SAME: for every post of the corpus with
    /// comments, the subtitle zone's first cue from its preview is the one
    /// it picks from the full first page, which replaces it after the
    /// landing.
    @Test func theFirstCueIsTheSameFromThePreviewAndThePage() async throws {
        let repository = makeRepository()
        let all = dataset.posts.map { PostID($0.postID) }
        _ = await repository.prefetchPreviews(for: all)
        let builder = SubtitleCommentBuilder()
        var compared = 0
        for id in all {
            guard let preview = repository.cachedTopComments(for: id) else { continue }
            let full = try await makeRepository().loadComments(for: id)
            for ticker in [true, false] {
                let fromPreview = builder.build(preview, postID: id, tickerIsRendering: ticker).first?.id
                let fromPage = builder.build(full, postID: id, tickerIsRendering: ticker).first?.id
                #expect(fromPreview == fromPage, "\(id.rawValue) (ticker \(ticker)): \(String(describing: fromPreview)) vs \(String(describing: fromPage))")
            }
            compared += 1
        }
        #expect(compared > 10, "the corpus compared too few posts: \(compared)")
    }

    /// A post whose comments open on reactions — the mock's dense posts —
    /// is no seed: its preview cannot tell the first cue, so it warms its
    /// first page on its own.
    @Test func aTrainOfReactionsIsLeftToItsOwnWarm() async {
        let repository = makeRepository()
        let dense = PostID("post-0000")
        let covered = await repository.prefetchPreviews(for: [dense])
        #expect(!covered.contains(dense))
        #expect(!repository.holdsComments(for: dense))
    }
}

/// When a preview can tell the subtitle zone's first cue (#2003): pure.
struct PreviewDecidesFirstCueTests {
    private func entry(_ body: String, replies: Int = 0) -> CommentEntry {
        CommentEntry(
            id: UUID().uuidString, authorID: ProfileID("a"), authorName: "A", authorHandle: "a",
            body: body, createdAt: Date(timeIntervalSince1970: 0), replyCount: replies
        )
    }

    private let thought = "This is the part that stayed with me all week"
    private let reaction = "😂"

    @Test func aThoughtFirstDecides() {
        #expect(SubtitleCommentBuilder.previewDecidesFirstCue([entry(thought), entry(reaction)], isWholeTopLevel: false))
        // A thought with replies of its own still comes first.
        #expect(SubtitleCommentBuilder.previewDecidesFirstCue([entry(thought, replies: 3)], isWholeTopLevel: false))
    }

    @Test func aTrainOfReactionsDoesNot() {
        let train = Array(repeating: entry(reaction), count: 5)
        #expect(!SubtitleCommentBuilder.previewDecidesFirstCue(train, isWholeTopLevel: false))
        // The whole top level, with no replies: the floor picks the same.
        #expect(SubtitleCommentBuilder.previewDecidesFirstCue(Array(train.prefix(3)), isWholeTopLevel: true))
    }

    /// Replies the page threads in before the first thought could be one.
    @Test func repliesBeforeTheThoughtDoNot() {
        #expect(!SubtitleCommentBuilder.previewDecidesFirstCue([entry(reaction, replies: 2), entry(thought)], isWholeTopLevel: false))
        #expect(!SubtitleCommentBuilder.previewDecidesFirstCue([entry(reaction, replies: 2)], isWholeTopLevel: true))
    }

    @Test func noCommentsDecides() {
        #expect(SubtitleCommentBuilder.previewDecidesFirstCue([], isWholeTopLevel: true))
    }
}
