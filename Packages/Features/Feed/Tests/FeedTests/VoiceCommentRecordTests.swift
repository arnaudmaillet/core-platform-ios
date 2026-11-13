import AuthInterface
import CoreContracts
import CoreModels
import CoreNavigation
import CoreNetworking
import CoreNetworkingMocks
import FeedInterface
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Feed

/// A source that takes voice comments (#2309): it records every upload and
/// every create, in order, can hold an upload until told and fail creates.
///
/// ⚠️ A CLASS WITH A LOCK, NOT AN ACTOR, so the synchronous `settle`
/// conditions can read it.
private final class VoiceCommentSource: CommentsProviding, @unchecked Sendable {
    struct Created: Equatable {
        let body: String
        let attachment: CommentAttachment?
        let parentID: String?
        let commentID: String
    }

    private let lock = NSLock()
    private var recordedCalls: [String] = []
    private var recordedCreates: [Created] = []
    private var createFailures: Int
    private var holdingUpload: Bool
    private let seeded: [CommentEntry]

    init(seeded: [CommentEntry] = [], failingCreates: Int = 0, holdingUpload: Bool = false) {
        self.seeded = seeded
        createFailures = failingCreates
        self.holdingUpload = holdingUpload
    }

    var calls: [String] { lock.withLock { recordedCalls } }
    var created: [Created] { lock.withLock { recordedCreates } }
    func release() { lock.withLock { holdingUpload = false } }

    nonisolated var uploadsCommentVoices: Bool { true }

    func loadComments(for postID: PostID) async throws -> [CommentEntry] { seeded }

    func uploadCommentVoice(_ take: CommentVoiceTake, commentID: String) async throws -> PostVoice {
        lock.withLock { recordedCalls.append("upload:\(commentID)") }
        // Bounded (#1046): a hold its test never released ends on its own.
        for _ in 0..<2_000 where lock.withLock({ holdingUpload }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        return PostVoice(
            assetID: "asset-\(commentID)", url: URL(string: "https://cdn.example/\(commentID).m4a"),
            duration: take.servedDuration, waveform: take.waveform
        )
    }

    func addComment(_ body: String, to postID: PostID, parentID: String?, commentID: String) async throws -> CommentEntry {
        try await addComment(body, attachment: nil, to: postID, parentID: parentID, commentID: commentID)
    }

    func addComment(
        _ body: String, attachment: CommentAttachment?, to postID: PostID, parentID: String?, commentID: String
    ) async throws -> CommentEntry {
        let fails: Bool = lock.withLock {
            recordedCalls.append("add:\(commentID)")
            recordedCreates.append(Created(body: body, attachment: attachment, parentID: parentID, commentID: commentID))
            guard createFailures > 0 else { return false }
            createFailures -= 1
            return true
        }
        if fails { throw CommentsError.transport(message: "offline") }
        return CommentEntry(
            id: commentID, authorID: ProfileID("prof-me"), authorName: "Me", authorHandle: "me",
            body: body, attachment: attachment, createdAt: Date(timeIntervalSince1970: 100), parentID: parentID
        )
    }
}

/// Words only: the comments' field records nothing from it.
private struct WordsOnlySource: CommentsProviding {
    func loadComments(for postID: PostID) async throws -> [CommentEntry] { [] }
    func addComment(_ body: String, to postID: PostID, parentID: String?, commentID: String) async throws -> CommentEntry {
        throw CommentsError.transport(message: "not used")
    }
}

private struct OnePostFeed: FeedProviding {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPage(afterToken token: String) async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        FeedEntry(
            post: Post(id: id, authorID: ProfileID("prof-1"), caption: "hi", attachments: [], publishedAt: Date(timeIntervalSince1970: 0)),
            author: AuthorSummary(id: ProfileID("prof-1"), handle: "ava", displayName: "Ava", avatarURL: nil),
            likeCount: 0
        )
    }
}

private final class GateHolder: UIViewController, MemberGateProviding {
    let memberGate: any MemberGating
    init(member: Bool) {
        memberGate = MemberGate(isMember: member)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
}

private func comment(_ id: String, _ body: String = "nice") -> CommentEntry {
    CommentEntry(
        id: id, authorID: ProfileID("prof-1"), authorName: "Ava", authorHandle: "ava", body: body,
        createdAt: Date(timeIntervalSince1970: 0)
    )
}

/// A take on disk, as the recorder leaves one.
private func take(duration: TimeInterval = 12.64) throws -> CommentVoiceTake {
    let url = FileManager.default.temporaryDirectory.appending(path: "comment-take-\(UUID().uuidString).m4a")
    try Data(repeating: 7, count: 4_096).write(to: url)
    return CommentVoiceTake(fileURL: url, duration: duration, waveform: (0..<100).map { UInt8($0 % 32) })
}

/// Recording a voice comment (#2309, A): the comments' field records a
/// minute-long voice comment — the conversation's hold, lock, pause, listen
/// back and send — and a tap still types; the take uploads, then the comment
/// is created carrying it, optimistic as a sent message is, with a retry on
/// failure; a reply's voice answers its parent; a guest is gated.
@MainActor
struct VoiceCommentRecordTests {
    /// A look budget, not a deadline (#1046).
    private static let looks = 3_000

    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<Self.looks where !condition() {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Grace for "nothing should have happened".
    private func settle() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(150))
    }

    private func page(_ source: any CommentsProviding) -> (PostDetailViewController, UIWindow) {
        let controller = PostDetailViewController(
            viewModel: PostDetailViewModel(postID: PostID("post-1"), repository: OnePostFeed(), commentsProvider: source),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return (controller, window)
    }

    private func makeViewModel(_ source: any CommentsProviding) -> PostDetailViewModel {
        PostDetailViewModel(postID: PostID("post-1"), repository: OnePostFeed(), commentsProvider: source)
    }

    private static func voiceTake(_ take: CommentVoiceTake) -> ConversationThreadVoiceTake {
        ConversationThreadVoiceTake(fileURL: take.fileURL, duration: take.duration, waveform: take.waveform)
    }

    // MARK: - The contract

    /// The comments' two contracts record a voice comment: a minute, the
    /// timer in seconds (#2294), VoiceOver's own words — and its recorder
    /// stops at the minute.
    @Test func theCommentsRecordAVoiceCommentOfAMinuteInSeconds() {
        for contract in [ComposerConfiguration.comments, .commentsSheet] {
            #expect(contract.voice == .comment)
            #expect(contract.voice.records)
            #expect(contract.voice.limit == 60)
            #expect(contract.voice.timerStyle == .seconds)
            #expect(contract.voice.recordActionName == "Record voice comment")
        }
        #expect(VoiceComposer(for: .comment, draftKey: nil).recorder.limit == 60)
    }

    /// A post's comments from a source that takes voices: the field's hold
    /// records a voice comment, the field says so and VoiceOver offers it —
    /// and a tap still types: focused, the field writes and its long press
    /// records nothing.
    @Test func thePostsFieldHoldsForAVoiceCommentAndATapStillTypes() throws {
        let (controller, window) = page(VoiceCommentSource())
        let bar = controller.composeBar
        // ⚠️ Focused, but with no system keyboard (`raisesNoKeyboard`), and
        // given back however the test ends.
        defer {
            bar.debugTextView.resignFirstResponder()
            window.isHidden = true
        }
        bar.debugTextView.raisesNoKeyboard()
        #expect(bar.configuration.voice == .comment)
        let composer = try #require(controller.voiceComposer, "nothing records the comments' hold")
        #expect(composer.recorder.limit == 60)
        #expect(composer.debugStrip.timerStyle == .seconds)
        #expect(bar.speaksFromField)
        #expect(bar.debugFieldHoldBegins, "the field's hold doesn't record")
        #expect(bar.debugPlaceholder == CommentsInputBar.speakOrWritePlaceholder)
        #expect(bar.debugTextView.accessibilityCustomActions?.map(\.name) == ["Record voice comment"])

        bar.debugTextView.becomeFirstResponder()
        try #require(bar.debugTextView.isFirstResponder, "a tap didn't type")
        #expect(!bar.debugFieldHoldBegins, "the focused field's long press records")
        #expect(composer.phase == .idle)
    }

    /// The sheet's composer records the same voice comment.
    @Test func theSheetsFieldRecordsTheSameVoiceComment() {
        let (controller, window) = page(VoiceCommentSource())
        defer { window.isHidden = true }
        controller.setComposerBare()
        #expect(controller.composeBar.configuration.voice == .comment)
        #expect(controller.composeBar.configuration.column == .none)
        #expect(controller.composeBar.debugFieldHoldBegins)
    }

    /// A source that carries no voice: the field only writes, and promises
    /// nothing.
    @Test func aSourceWithoutVoicesRecordsNothing() {
        let (controller, window) = page(WordsOnlySource())
        defer { window.isHidden = true }
        let bar = controller.composeBar
        #expect(bar.configuration.voice == .none)
        #expect(controller.voiceComposer == nil)
        #expect(!bar.speaksFromField)
        #expect(bar.debugPlaceholder != CommentsInputBar.speakOrWritePlaceholder)
        #expect(bar.debugTextView.accessibilityCustomActions == nil)
    }

    // MARK: - Sending

    /// A take from the comments' hold: uploaded first, then the comment is
    /// created carrying it as `.voice`, with the typed words as its body,
    /// both under one key (#795).
    @Test func aHeldTakeUploadsThenTheCommentCarriesIt() async throws {
        let source = VoiceCommentSource()
        let (controller, window) = page(source)
        defer { window.isHidden = true }
        let composer = try #require(controller.voiceComposer)
        let recorded = try take()
        controller.composeBar.draftText = "Listen to this"
        composer.onSend?(Self.voiceTake(recorded))
        #expect(await settle { source.created.count == 1 })
        let created = try #require(source.created.first)
        #expect(source.calls == ["upload:\(created.commentID)", "add:\(created.commentID)"], "not uploaded first")
        #expect(created.attachment == .voice(PostVoice(
            assetID: "asset-\(created.commentID)", url: URL(string: "https://cdn.example/\(created.commentID).m4a"),
            duration: 12.6, waveform: recorded.waveform
        )))
        #expect(created.body == "Listen to this")
        #expect(created.parentID == nil)
        #expect(controller.composeBar.draftText.isEmpty, "the words stayed behind once sent with the voice")
    }

    /// A reply's voice answers its parent — even when the reply's keyboard
    /// went while it recorded. A reply armed over the focused field still
    /// holds for a voice.
    @Test func aRepliesVoiceGoesToTheParent() async throws {
        let source = VoiceCommentSource(seeded: [comment("c1")])
        let (controller, window) = page(source)
        let bar = controller.composeBar
        // ⚠️ A reply focuses the field (`enterReplyState`) and this test waits
        // with it focused: no system keyboard (`raisesNoKeyboard`), and given
        // back however it ends.
        defer {
            bar.debugTextView.resignFirstResponder()
            window.isHidden = true
        }
        bar.debugTextView.raisesNoKeyboard()
        let composer = try #require(controller.voiceComposer)
        controller.enterReplyState(for: CommentDisplayModel(entry: comment("c1")))
        #expect(bar.debugFieldHoldBegins, "a reply's voice can't be held")
        // The hold begins, then the keyboard goes over the empty field.
        composer.onPhaseChange?(.holding(revealed: true))
        bar.onIdleDismiss?()
        composer.onSend?(Self.voiceTake(try take()))
        #expect(await settle { source.created.count == 1 })
        #expect(source.created.first?.parentID == "c1", "the reply's voice went top-level")
        composer.onPhaseChange?(.idle)

        // Replying again, with the keyboard up all along.
        controller.enterReplyState(for: CommentDisplayModel(entry: comment("c1")))
        composer.onSend?(Self.voiceTake(try take()))
        #expect(await settle { source.created.count == 2 })
        #expect(source.created.last?.parentID == "c1")
    }

    /// Optimistic, as a sent message is: the row shows at once — the voice,
    /// playing from the take, a spinner where its time goes — and the
    /// server's comment takes its place, the same row, arriving once.
    @Test func theSendingRowShowsTheVoiceAndIsReplacedOnSuccess() async throws {
        let source = VoiceCommentSource(seeded: [comment("c1")], holdingUpload: true)
        let viewModel = makeViewModel(source)
        var rows: [CommentDisplayModel] = []
        var popularRows: [CommentDisplayModel] = []
        var arrivals: [String] = []
        viewModel.onCommentsChange = { if case .loaded(let models) = $0 { rows = models } }
        viewModel.onPopularCommentsChange = { if case .loaded(let models) = $0 { popularRows = models } }
        viewModel.onCommentPosted = { arrivals.append($0) }
        viewModel.viewDidLoad()
        #expect(await settle { rows.contains { $0.id == "c1" } })
        #expect(viewModel.acceptsVoiceComments)

        let recorded = try take()
        viewModel.submitVoiceComment(recorded, text: "", parentID: nil)
        let sending = try #require(rows.first)
        #expect(sending.id != "c1")
        #expect(sending.delivery == .sending)
        #expect(sending.metaText.isEmpty, "a time beside a comment still on its way")
        #expect(sending.body.isEmpty)
        #expect(sending.attachment?.voice?.url == recorded.fileURL, "the sending row doesn't play the take")
        #expect(sending.attachment?.voice?.duration == 12.6)
        #expect(arrivals == [sending.id])

        source.release()
        #expect(await settle { rows.first { $0.id == sending.id }?.delivery == nil })
        let landed = try #require(rows.first)
        #expect(landed.id == sending.id, "the server's comment didn't take the sending row's place")
        #expect(rows.filter { $0.id == sending.id }.count == 1)
        #expect(landed.attachment?.voice?.assetID == "asset-\(sending.id)")
        #expect(landed.attachment?.voice?.url == recorded.fileURL, "the author's own voice no longer plays from the take")
        #expect(!landed.metaText.isEmpty)
        #expect(viewModel.pendingVoiceComments.isEmpty)
        #expect(arrivals.count == 1, "the landed comment arrived a second time")
        if !popularRows.isEmpty {
            #expect(popularRows.filter { $0.id == sending.id }.count == 1)
            #expect(popularRows.first { $0.id == sending.id }?.delivery == nil)
        }
    }

    /// A failed voice comment keeps its row, failed; sent again, it is the
    /// same take under the same key — not uploaded twice when only the
    /// create failed — and it lands.
    @Test func aFailureShowsRetryAndARetryResendsTheSameTake() async throws {
        let source = VoiceCommentSource(failingCreates: 1)
        let viewModel = makeViewModel(source)
        var rows: [CommentDisplayModel] = []
        var refusals: [Bool] = []
        viewModel.onCommentsChange = { if case .loaded(let models) = $0 { rows = models } }
        viewModel.onVoiceCommentFailed = { refusals.append($0) }
        viewModel.viewDidLoad()
        #expect(await settle { viewModel.acceptsVoiceComments && rows.isEmpty })

        viewModel.submitVoiceComment(try take(), text: "Again", parentID: nil)
        #expect(await settle { rows.first?.delivery == .failed })
        #expect(refusals == [false])
        let id = try #require(rows.first?.id)
        #expect(rows.first?.attachment?.voice != nil, "the failed row lost its voice")

        viewModel.retryVoiceComment(id)
        #expect(rows.first?.delivery == .sending)
        #expect(await settle { rows.first?.delivery == nil })
        #expect(rows.first?.id == id)
        #expect(source.calls == ["upload:\(id)", "add:\(id)", "add:\(id)"], "uploaded twice, or sent under another key")
        let creates = source.created
        #expect(creates.map(\.body) == ["Again", "Again"])
        #expect(creates.count == 2 && creates[0].attachment == creates[1].attachment, "the retry sent another take")
        #expect(viewModel.pendingVoiceComments.isEmpty)
    }

    /// On the page: the failed row says so — the red mark, "Not sent" — and
    /// its tap sends it again.
    @Test func theFailedRowsTapSendsItAgain() async throws {
        let source = VoiceCommentSource(seeded: [comment("c1")], failingCreates: 1)
        let (controller, window) = page(source)
        defer { window.isHidden = true }
        controller.sendVoiceComment(try take())
        #expect(await settle { source.created.count == 1 })
        let id = try #require(source.created.first?.commentID)
        func row() -> CommentRowView? {
            for stream in controller.streams {
                stream.collectionView.layoutIfNeeded()
                for cell in stream.collectionView.visibleCells {
                    guard let row = PostDetailViewController.commentRow(in: cell), row.delivery == .failed else { continue }
                    return row
                }
            }
            return nil
        }
        #expect(await settle { row() != nil }, "no failed row on the page")
        let failed = try #require(row())
        #expect(failed.accessibilityValue == "Not sent. Tap to try again.")
        failed.onReplyTap?()
        #expect(await settle { source.created.count == 2 })
        #expect(source.created.last?.commentID == id)
        #expect(source.calls.filter { $0.hasPrefix("upload:") }.count == 1)
    }

    // MARK: - A guest

    /// A guest records nothing — the field's hold doesn't begin, VoiceOver
    /// offers no recording — and a take never leaves: the member gate, as for
    /// a typed comment.
    @Test func aGuestIsGated() async throws {
        let guest = GateHolder(member: false)
        let guestBar = CommentsInputBar()
        guest.view.addSubview(guestBar)
        guestBar.onVoiceHold = { _ in }
        #expect(guestBar.configuration.voice == .comment)
        #expect(!guestBar.debugFieldHoldBegins, "a guest's hold records")
        #expect(guestBar.debugTextView.accessibilityCustomActions == nil, "VoiceOver records for a guest")

        let member = GateHolder(member: true)
        let memberBar = CommentsInputBar()
        member.view.addSubview(memberBar)
        memberBar.onVoiceHold = { _ in }
        #expect(memberBar.debugFieldHoldBegins)

        let source = VoiceCommentSource()
        let controller = PostDetailViewController(
            viewModel: makeViewModel(source), imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let holder = GateHolder(member: false)
        holder.addChild(controller)
        holder.view.addSubview(controller.view)
        controller.didMove(toParent: holder)
        controller.sendVoiceComment(try take())
        await settle()
        #expect(source.calls.isEmpty, "a guest's voice comment was sent")
        #expect(controller.viewModel.pendingVoiceComments.isEmpty)
        withExtendedLifetime((guest, member, holder)) {}
    }
}

/// The mock BFF takes a voice comment end to end (#2309): the take uploaded
/// through media.v1, the comment created carrying it, and served back with
/// it — a reply's too.
struct VoiceCommentMockRoundTripTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    @Test func theMockTakesAVoiceCommentAndServesItBack() async throws {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        let blobs = MockBlobStore()
        MockAuthService().register(on: bff)
        MockSocialServices(dataset: dataset).register(on: bff)
        MockMediaService(store: blobs).register(on: bff)
        MockCommentService(dataset: dataset).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = CommentsRepository(
            commentClient: Comment_V1_CommentServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: Session(),
            mediaUploader: MediaAssetUploader(
                mediaClient: Media_V1_MediaServiceClient(client: client),
                transport: MockMediaUploadTransport(store: blobs)
            )
        )
        #expect(repository.uploadsCommentVoices)
        let post = try #require(dataset.posts.first { $0.authorProfileID == MockSocialDataset.viewerProfileID })
        let postID = PostID(post.postID)

        let voice = try await repository.uploadCommentVoice(try take(), commentID: "voice-comment-1")
        #expect(!voice.assetID.isEmpty && voice.url != nil)
        #expect(voice.duration == 12.6)
        let entry = try await repository.addComment(
            "", attachment: .voice(voice), to: postID, parentID: nil, commentID: "voice-comment-1"
        )
        #expect(entry.attachment == .voice(voice))
        #expect(entry.body.isEmpty, "a voice alone is a comment")
        let paths = bff.recordedRequests.map(\.path)
        let ticket = try #require(paths.firstIndex(of: "/media.v1.MediaService/IssueUploadTicket"))
        let create = try #require(paths.firstIndex(of: "/comment.v1.CommentService/CreateComment"))
        #expect(ticket < create, "the comment was created before its voice went up")

        let page = try await repository.loadCommentsPage(for: postID, after: nil)
        let served = try #require(page.entries.first { $0.id == "voice-comment-1" })
        #expect(served.attachment?.voice?.assetID == voice.assetID)
        #expect(served.attachment?.voice?.duration == 12.6)

        // A reply's voice, with words.
        let replyVoice = try await repository.uploadCommentVoice(try take(duration: 4), commentID: "voice-reply-1")
        _ = try await repository.addComment(
            "Agreed", attachment: .voice(replyVoice), to: postID, parentID: "voice-comment-1", commentID: "voice-reply-1"
        )
        let replies = try await repository.loadReplies(for: postID, to: "voice-comment-1", after: nil)
        let reply = try #require(replies.entries.first { $0.id == "voice-reply-1" })
        #expect(reply.parentID == "voice-comment-1")
        #expect(reply.body == "Agreed")
        #expect(reply.attachment?.voice?.duration == 4)
    }
}
