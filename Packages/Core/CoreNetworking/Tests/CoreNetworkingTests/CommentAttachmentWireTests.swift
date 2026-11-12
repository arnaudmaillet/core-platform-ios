import Connect
import CoreContracts
import CoreModels
import CoreNetworkingMocks
import Foundation
import SwiftProtobuf
import Testing
@testable import CoreNetworking

/// A comment's attachment on the wire (#2309) and the mock's voice
/// comments: a value by kind, voice first, an unknown kind kept safely, the
/// text optional beside it.
struct CommentAttachmentWireTests {
    private let voice = PostVoice(
        assetID: "voice-pair1", url: URL(string: "https://cdn.example/c.m4a?sig=a+b"), duration: 3.3,
        waveform: (0..<100).map { UInt8($0 % 32) }
    )

    // MARK: - The wire

    @Test func aVoiceRidesTheCommentViewAndSurvivesTheWire() throws {
        var view = Comment_V1_CommentView()
        view.commentID = "c1"
        view.body = ""
        CommentAttachmentWire.write(.voice(voice), to: &view)
        let decoded = try Comment_V1_CommentView(serializedBytes: try view.serializedData())
        #expect(CommentAttachmentWire.attachment(in: decoded) == .voice(voice))
        #expect(decoded.body.isEmpty, "a voice alone is a comment")
        #expect(!decoded.hasGif, "a voice is never the GIF")
    }

    @Test func aVoiceRidesTheCreateRequest() throws {
        var request = Comment_V1_CreateCommentRequest()
        request.commentID = "c2"
        request.body = "Listen to this"
        CommentAttachmentWire.write(.voice(voice), to: &request)
        let decoded = try Comment_V1_CreateCommentRequest(serializedBytes: try request.serializedData())
        #expect(CommentAttachmentWire.attachment(in: decoded)?.voice == voice)
        #expect(decoded.body == "Listen to this")
    }

    @Test func aCommentWithoutAnAttachmentHasNone() {
        var view = Comment_V1_CommentView()
        view.body = "Just words"
        #expect(CommentAttachmentWire.attachment(in: view) == nil)
    }

    /// ⚠️ THE EPIC'S ACCEPTANCE: a kind this build doesn't know is kept as
    /// `.unsupported`, and the comment still reads with its text.
    @Test func anUnknownKindIsUnsupportedAndTheTextStays() throws {
        var view = Comment_V1_CommentView()
        view.body = "From a later app"
        PostVoiceWire.write(voice, to: &view) // an unrelated undeclared field beside it
        let reference = "cpattach://v1?kind=hologram&a=asset-9&w=640&h=480"
        UnknownFieldWire.write(reference, field: CommentAttachmentWire.fieldNumber, to: &view)
        let decoded = try Comment_V1_CommentView(serializedBytes: try view.serializedData())
        let attachment = try #require(CommentAttachmentWire.attachment(in: decoded))
        #expect(attachment == .unsupported(CommentAttachment.Kind(rawValue: "hologram")))
        #expect(attachment.voice == nil && !attachment.isSupported)
        #expect(decoded.body == "From a later app")
        #expect(PostVoiceWire.voice(in: decoded) == voice, "a neighbouring field was disturbed")
    }

    @Test func aMalformedReferenceIsNone() {
        for reference in ["cpattach://v1?kind=voice&a=x", "cpattach://v1?a=x&ms=1000", "cpvoice://v1?d=2", "nonsense"] {
            var view = Comment_V1_CommentView()
            view.body = "words"
            UnknownFieldWire.write(reference, field: CommentAttachmentWire.fieldNumber, to: &view)
            #expect(CommentAttachmentWire.attachment(in: view) == nil, "\(reference)")
        }
    }

    // MARK: - The mock

    private func client() -> Comment_V1_CommentServiceClient {
        let bff = MockBFF()
        MockCommentService(dataset: MockSocialDataset()).register(on: bff)
        return Comment_V1_CommentServiceClient(
            client: ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        )
    }

    private func topLevel(_ postID: String, using comments: Comment_V1_CommentServiceClient) async throws -> [Comment_V1_CommentView] {
        var request = Comment_V1_ListTopLevelRequest()
        request.postID = postID
        return try await comments.listTopLevel(request: request, headers: [:]).result.get().comments
    }

    /// Each voice post carries a voice alone, a voice with words and a voice
    /// reply, every one playable and under a comment's 60 s.
    @Test func theSeededPostsCarryVoiceComments() async throws {
        let comments = client()
        for postID in MockCommentService.voiceCommentPostIDs {
            let page = try await topLevel(postID, using: comments)
            let alone = try #require(page.first { $0.commentID == "\(postID)-voice-0" })
            let spoken = try #require(page.first { $0.commentID == "\(postID)-voice-1" })
            #expect(alone.body.isEmpty && !spoken.body.isEmpty)
            for view in [alone, spoken] {
                let carried = try #require(CommentAttachmentWire.attachment(in: view)?.voice, "\(view.commentID)")
                #expect(carried.url != nil && carried.waveform.count == 100)
                #expect(carried.duration > 0 && carried.duration <= 60)
            }
            // The plain pair stays plain.
            #expect(page.filter { $0.commentID.hasSuffix("-c0") || $0.commentID.hasSuffix("-c1") }
                .allSatisfy { CommentAttachmentWire.attachment(in: $0) == nil })

            let parent = try #require(page.first { $0.commentID == "\(postID)-c0" })
            #expect(parent.replyCount == 1)
            var replies = Comment_V1_ListRepliesRequest()
            replies.postID = postID
            replies.commentID = parent.commentID
            let reply = try #require(try await comments.listReplies(request: replies, headers: [:]).result.get().comments.first)
            #expect(reply.body.isEmpty && reply.parentID == parent.commentID)
            #expect(CommentAttachmentWire.attachment(in: reply)?.voice != nil)
        }
    }

    @Test func oneSeededCommentCarriesAnUnknownKind() async throws {
        let page = try await topLevel(MockCommentService.unsupportedAttachmentPostID, using: client())
        let future = page.filter { CommentAttachmentWire.attachment(in: $0)?.isSupported == false }
        #expect(future.count == 1)
        #expect(future.first.flatMap { CommentAttachmentWire.attachment(in: $0) }
            == .unsupported(MockCommentService.unsupportedAttachmentKind))
        #expect(future.first?.body.isEmpty == false, "the unknown kind's comment has words to fall back on")
    }

    /// Posts outside the set keep their comments plain.
    @Test func otherPostsCarryNoAttachment() async throws {
        let comments = client()
        for postID in ["post-0000", "post-0001", "post-0011", "post-0018"] {
            let page = try await topLevel(postID, using: comments)
            #expect(page.allSatisfy { CommentAttachmentWire.attachment(in: $0) == nil }, "\(postID)")
        }
    }

    /// A created comment is served with its voice, and with no words.
    @Test func createCommentKeepsItsAttachment() async throws {
        let comments = client()
        var create = Comment_V1_CreateCommentRequest()
        create.commentID = "mine-voice"
        create.postID = "post-0020"
        create.authorID = MockSocialDataset.viewerProfileID
        create.body = ""
        CommentAttachmentWire.write(.voice(voice), to: &create)
        _ = try await comments.createComment(request: create, headers: [:]).result.get()
        let served = try #require(try await topLevel("post-0020", using: comments).first { $0.commentID == "mine-voice" })
        #expect(CommentAttachmentWire.attachment(in: served) == .voice(voice))
        #expect(served.body.isEmpty)
    }
}
