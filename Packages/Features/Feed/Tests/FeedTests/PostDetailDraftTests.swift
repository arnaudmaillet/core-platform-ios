import CoreModels
import Foundation
import Testing
@testable import Feed

/// The view model of a post that does not exist yet — the "+" menu's Text Post.
///
/// It has nothing to load, so it must never reach the repository; it shows a
/// LOADED empty stream on its first frame, not a skeleton; and its first send
/// is the post itself, published as the composer's face, after which it is
/// exactly the view model of that post.
@MainActor
struct PostDetailDraftTests {
    private final class CountingFeed: FeedProviding, @unchecked Sendable {
        var postLoads = 0
        func cachedFirstPage() async -> [FeedEntry]? { nil }
        func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
        func loadPage(afterToken token: String) async throws -> FeedPage {
            FeedPage(entries: [], nextPageToken: nil, isCold: false)
        }
        func loadPost(_ id: PostID) async throws -> FeedEntry {
            postLoads += 1
            throw FeedError.transport(message: "a draft must not ask")
        }
    }

    private final class RecordingComments: CommentsProviding, @unchecked Sendable {
        var loads: [PostID] = []
        var added: [PostID] = []
        var viewer = ViewerIdentity(
            name: "Demo Viewer", avatarURL: nil, profileID: ProfileID("prof-me"), handle: "you"
        )
        func loadComments(for postID: PostID) async throws -> [CommentEntry] {
            loads.append(postID)
            return []
        }
        func viewerIdentity() async -> ViewerIdentity? { viewer }
        func addComment(_ body: String, to postID: PostID, parentID: String?) async throws -> CommentEntry {
            added.append(postID)
            return CommentEntry(
                id: "comment-\(added.count)", authorID: ProfileID("prof-me"), authorName: "Demo Viewer",
                authorHandle: "you", body: body, createdAt: Date()
            )
        }
    }

    private actor PublishLog {
        struct Call: Sendable {
            let text: String
            let author: AuthorSummary?
        }
        private(set) var calls: [Call] = []
        func record(_ text: String, _ author: AuthorSummary?) { calls.append(Call(text: text, author: author)) }
    }

    private struct Failure: Error {}

    nonisolated private static func entry(_ text: String, by author: AuthorSummary?) -> FeedEntry {
        let author = author ?? AuthorSummary(
            id: ProfileID("prof-first"), handle: "first", displayName: "First", avatarURL: nil
        )
        return FeedEntry(
            post: Post(id: PostID("post-new"), authorID: author.id, caption: text, attachments: [], publishedAt: Date()),
            author: author
        )
    }

    private func makeDraft(
        log: PublishLog, fails: Bool = false, delay: Duration = .zero
    ) -> PostDetailDraft {
        PostDetailDraft { text, author in
            await log.record(text, author)
            if delay > .zero { try await Task.sleep(for: delay) }
            if fails { throw Failure() }
            return PostDetailDraftTests.entry(text, by: author)
        }
    }

    private func settle(until condition: () -> Bool) async throws {
        var attempts = 0
        while !condition(), attempts < 300 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aDraftShowsALoadedEmptyStreamOnItsFirstFrame() {
        let model = PostDetailViewModel(
            draft: makeDraft(log: PublishLog()), repository: CountingFeed(), commentsProvider: RecordingComments()
        )
        var states: [PostDetailViewModel.CommentsState] = []
        model.onCommentsChange = { states.append($0) }

        model.viewDidLoad()

        #expect(states == [.loaded([])], "synchronously, and never a skeleton")
        #expect(model.isDraft)
        #expect(model.postID == nil)
    }

    @Test func aDraftNeverReachesTheRepository() async throws {
        let feed = CountingFeed()
        let comments = RecordingComments()
        let model = PostDetailViewModel(draft: makeDraft(log: PublishLog()), repository: feed, commentsProvider: comments)
        var viewer: ViewerIdentity?
        model.onViewerIdentityChange = { viewer = $0 }

        model.viewDidLoad()
        model.refresh()
        try await settle { viewer != nil }

        #expect(viewer?.name == "Demo Viewer", "the viewer IS asked for: they are the author")
        #expect(feed.postLoads == 0)
        #expect(comments.loads.isEmpty)
    }

    /// The first send is the post — trimmed, and by the face on the composer.
    @Test func theFirstSendPublishesAsTheComposersFace() async throws {
        let log = PublishLog()
        let model = PostDetailViewModel(draft: makeDraft(log: log), repository: CountingFeed(), commentsProvider: RecordingComments())
        var published: FeedEntry?
        model.onPublished = { published = $0 }

        model.submitComment("  Hello, world  ")
        try await settle { published != nil }

        let calls = await log.calls
        #expect(calls.map(\.text) == ["Hello, world"])
        #expect(calls.first?.author?.id == ProfileID("prof-me"))
        #expect(published?.post.caption == "Hello, world")
        #expect(model.postID == PostID("post-new"))
        #expect(model.isDraft == false)
    }

    /// Adopting the post puts the CAPTION up before the comments re-apply —
    /// the order that sizes the empty page around the caption row.
    @Test func adoptingSetsThePostBeforeTheComments() async throws {
        let model = PostDetailViewModel(draft: makeDraft(log: PublishLog()), repository: CountingFeed(), commentsProvider: RecordingComments())
        var events: [String] = []
        model.onPhaseChange = { phase in
            if case .content = phase { events.append("post") }
        }
        model.onCommentsChange = { state in
            if case .loaded = state { events.append("comments") } else { events.append("skeleton") }
        }
        var published = false
        model.onPublished = { _ in published = true }

        model.submitComment("Hello")
        try await settle { published }

        #expect(events.first == "post")
        #expect(events.contains("comments"))
        #expect(!events.contains("skeleton"), "the published post never flashes a skeleton")
    }

    @Test func afterPublishingASendIsACommentOnThePost() async throws {
        let comments = RecordingComments()
        let model = PostDetailViewModel(draft: makeDraft(log: PublishLog()), repository: CountingFeed(), commentsProvider: comments)
        var published = false
        model.onPublished = { _ in published = true }
        model.submitComment("The post")
        try await settle { published }
        var composing = true
        model.onComposingChange = { composing = $0 }
        try await settle { !composing || comments.loads.count > 0 }

        model.submitComment("A comment")
        try await settle { !comments.added.isEmpty }

        #expect(comments.added == [PostID("post-new")])
    }

    @Test func aFailedPublishHandsTheTextBackAndStaysADraft() async throws {
        let model = PostDetailViewModel(
            draft: makeDraft(log: PublishLog(), fails: true), repository: CountingFeed(), commentsProvider: RecordingComments()
        )
        var returned: String?
        model.onPublishFailed = { returned = $0 }

        model.submitComment("Hello")
        try await settle { returned != nil }

        #expect(returned == "Hello")
        #expect(model.isDraft)
    }

    /// Nobody to publish AS is a failure, not a quiet fallback to the
    /// account's first profile.
    @Test func aDraftWithNoKnownFacePublishesNothing() async throws {
        let log = PublishLog()
        let model = PostDetailViewModel(draft: makeDraft(log: log), repository: CountingFeed(), commentsProvider: nil)
        var returned: String?
        model.onPublishFailed = { returned = $0 }

        model.submitComment("Hello")
        try await settle { returned != nil }

        #expect(returned == "Hello")
        #expect(await log.calls.isEmpty)
        #expect(model.isDraft)
    }

    /// The face on screen is who the post is by — even when a later lookup
    /// would answer differently.
    @Test func aDraftPublishesAsTheFaceItShowed() async throws {
        let log = PublishLog()
        let comments = RecordingComments()
        let model = PostDetailViewModel(draft: makeDraft(log: log), repository: CountingFeed(), commentsProvider: comments)
        var shown: ViewerIdentity?
        model.onViewerIdentityChange = { shown = $0 }
        var published = false
        model.onPublished = { _ in published = true }
        model.viewDidLoad()
        try await settle { shown != nil }
        // A later lookup would answer with someone else.
        comments.viewer = ViewerIdentity(
            name: "Other", avatarURL: nil, profileID: ProfileID("prof-other"), handle: "other"
        )

        model.submitComment("Mine")
        try await settle { published }

        #expect(shown?.profileID == ProfileID("prof-me"))
        #expect(await log.calls.first?.author?.id == ProfileID("prof-me"), "the face it showed, not the later lookup")
    }

    @Test func aSecondSendWhilePublishingIsRefused() async throws {
        let log = PublishLog()
        let model = PostDetailViewModel(
            draft: makeDraft(log: log, delay: .milliseconds(200)), repository: CountingFeed(), commentsProvider: RecordingComments()
        )
        var published = false
        model.onPublished = { _ in published = true }

        model.submitComment("Once")
        model.submitComment("Twice")
        try await settle { published }

        #expect(await log.calls.map(\.text) == ["Once"])
    }
}
