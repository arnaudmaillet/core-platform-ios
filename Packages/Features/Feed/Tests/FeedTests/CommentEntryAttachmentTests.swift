import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Feed

private struct SignedInSession: AuthSessionProviding {
    func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
    func stateUpdates() async -> AsyncStream<AuthState> {
        AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
    }
    func logout() async {}
}

/// A provider with no attachment path: only the text-only call.
private struct WordsOnlyProvider: CommentsProviding {
    func loadComments(for postID: PostID) async throws -> [CommentEntry] { [] }
    func addComment(_ body: String, to postID: PostID, parentID: String?, commentID: String) async throws -> CommentEntry {
        CommentEntry(id: commentID, authorID: ProfileID("me"), authorName: "Me", authorHandle: "me", body: body, createdAt: Date())
    }
}

/// A comment's attachment through the client (#2309, piece 1): read from
/// the wire into `CommentEntry`, sent with a new comment, kept by the
/// device tier, by an approval and by the row's model — and an unknown kind
/// never costs the comment its text.
struct CommentEntryAttachmentTests {
    private let voice = PostVoice(
        assetID: "voice-short", url: URL(string: "https://cdn.example/c.m4a"), duration: 2.9,
        waveform: (0..<100).map { UInt8($0 % 32) }
    )

    private func makeRepository() -> CommentsRepository {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockCommentService(dataset: dataset).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return CommentsRepository(
            commentClient: Comment_V1_CommentServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: SignedInSession()
        )
    }

    private func entry(body: String, attachment: CommentAttachment?) -> CommentEntry {
        CommentEntry(
            id: "c1", authorID: ProfileID("prof-1"), authorName: "Ava", authorHandle: "ava", body: body,
            attachment: attachment, createdAt: Date(timeIntervalSince1970: 0), isHeld: true
        )
    }

    // MARK: - From the mock

    @Test func theMocksVoiceCommentsReachTheEntries() async throws {
        let repository = makeRepository()
        let postID = try #require(MockCommentService.voiceCommentPostIDs.first)
        let comments = try await repository.loadComments(for: PostID(postID))
        let alone = try #require(comments.first { $0.id == "\(postID)-voice-0" })
        #expect(alone.body.isEmpty)
        #expect(alone.attachment?.kind == .voice && alone.attachment?.voice?.url != nil)
        let spoken = try #require(comments.first { $0.id == "\(postID)-voice-1" })
        #expect(!spoken.body.isEmpty && spoken.attachment?.voice != nil)
        // The voice reply, threaded under its parent with the page.
        let reply = try #require(comments.first { $0.parentID == "\(postID)-c0" })
        #expect(reply.body.isEmpty && reply.attachment?.voice != nil)
        #expect(comments.first { $0.id == "\(postID)-c0" }?.attachment == nil)
    }

    /// ⚠️ THE EPIC'S ACCEPTANCE: an attachment of a kind this build doesn't
    /// know is ignored safely — the comment loads, keeps its text, and
    /// carries `.unsupported`, which nothing plays.
    @Test func anUnknownKindKeepsTheCommentAndItsText() async throws {
        let repository = makeRepository()
        let comments = try await repository.loadComments(for: PostID(MockCommentService.unsupportedAttachmentPostID))
        let future = try #require(comments.first { $0.attachment?.isSupported == false })
        #expect(future.attachment == .unsupported(MockCommentService.unsupportedAttachmentKind))
        #expect(future.attachment?.voice == nil)
        #expect(!future.body.isEmpty)
        #expect(CommentDisplayModel(entry: future).body == future.body)
    }

    @Test func aVoiceCommentIsSentAndServedBack() async throws {
        let repository = makeRepository()
        let post = PostID("post-0020")
        let created = try await repository.addComment(
            "", attachment: .voice(voice), to: post, parentID: nil, commentID: "voice-draft-1"
        )
        #expect(created.attachment == .voice(voice) && created.body.isEmpty)
        let served = try #require(try await repository.loadComments(for: post).first { $0.id == "voice-draft-1" })
        #expect(served.attachment == .voice(voice))
        #expect(served.body.isEmpty)
    }

    @Test func aTextCommentCarriesNoAttachment() async throws {
        let created = try await makeRepository().addComment("Words", to: PostID("post-0020"), parentID: nil)
        #expect(created.attachment == nil)
    }

    /// A provider with no attachment path refuses one rather than posting the
    /// words without it, and still posts words alone.
    @Test func aWordsOnlyProviderRefusesAnAttachment() async throws {
        let provider = WordsOnlyProvider()
        await #expect(throws: CommentsError.self) {
            try await provider.addComment("", attachment: .voice(voice), to: PostID("p"), parentID: nil, commentID: "x")
        }
        let words = try await provider.addComment("Hi", attachment: nil, to: PostID("p"), parentID: nil, commentID: "y")
        #expect(words.body == "Hi")
    }

    // MARK: - Kept along the way

    @Test func approvalAndTheRowsModelKeepTheAttachment() {
        let held = entry(body: "", attachment: .voice(voice))
        #expect(held.released().attachment == .voice(voice), "approving dropped the voice")
        #expect(CommentDisplayModel(entry: held).attachment == .voice(voice))
        #expect(CommentDisplayModel(entry: held).body.isEmpty)
    }

    @Test func theDeviceTierKeepsTheAttachment() throws {
        let cases: [CommentAttachment?] = [.voice(voice), .unsupported(CommentAttachment.Kind(rawValue: "video")), nil]
        for attachment in cases {
            let data = try JSONEncoder().encode(CommentsDiskTier.Record(entry(body: "", attachment: attachment)))
            #expect(try JSONDecoder().decode(CommentsDiskTier.Record.self, from: data).entry.attachment == attachment)
        }
    }

    /// A record from before #2309 reads with none; one whose attachment this
    /// build can't read keeps the comment, and so the page.
    @Test func anOldOrUnreadableStoredAttachmentIsNone() throws {
        let data = try JSONEncoder().encode(CommentsDiskTier.Record(entry(body: "Words", attachment: .voice(voice))))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "attachment")
        let old = try JSONDecoder().decode(CommentsDiskTier.Record.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.entry.attachment == nil && old.entry.body == "Words")
        json["attachment"] = ["kind": "voice", "voice": "not a voice"]
        let broken = try JSONDecoder().decode(CommentsDiskTier.Record.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(broken.entry.attachment == nil && broken.entry.body == "Words")
    }
}
