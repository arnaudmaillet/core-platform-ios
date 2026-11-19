import CoreModels
import Foundation
import Testing
import UIKit
@testable import Chat

/// A conversation is the text post's screen, Chat's own since #2380 —
/// for an existing thread, a draft and a shared link alike.
@MainActor
struct ChatFeatureBuilderThreadTests {
    private actor Stub: ChatProviding {
        func viewerProfileID() async throws -> ProfileID { ProfileID("me") }
        func loadConversations() async throws -> [Conversation] { [] }
        func loadMessages(in conversationID: ConversationID) async throws -> [ChatMessage] { [] }
        func send(_ body: String, to conversationID: ConversationID, replyingTo replyToID: String?) async throws -> ChatMessage {
            ChatMessage(id: "sent", senderID: ProfileID("me"), body: body, createdAt: Date(), isMine: true)
        }
        func markRead(_ conversationID: ConversationID, upTo messageID: String) async throws {}
        func directConversation(with profileID: ProfileID) async throws -> ConversationID { ConversationID("dm") }
    }

    /// The thread's footer has no emote strip any more (#680): the peer pill
    /// leads it, and the composer's emote button is the way to emotes.
    @Test func anExistingThreadIsTheTextPostsScreen() throws {
        let builder = ChatFeatureBuilder(repository: Stub())
        let built = builder.makeConversationViewController(for: ConversationID("c1"))
        let screen = try #require(built as? ConversationThreadViewController)
        #expect(screen.mode == .full)
    }

    @Test func aSharedLinkReachesTheScreenAsItsDraft() throws {
        let builder = ChatFeatureBuilder(repository: Stub())
        let built = builder.makeDraftConversationViewController(
            with: ProfileID("them"), displayName: "Ava", prefill: "https://example.test/p/1"
        )
        let screen = try #require(built as? ConversationThreadViewController)
        #expect(screen.prefill == "https://example.test/p/1")
    }
}
