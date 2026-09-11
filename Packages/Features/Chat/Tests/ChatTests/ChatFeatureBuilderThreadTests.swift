import CoreModels
import FeedInterface
import Foundation
import Testing
import UIKit
@testable import Chat

/// A conversation is drawn by whoever `threadScreens` names — Feed's text-post
/// screen in the app — for an existing thread, a draft and a shared link alike,
/// with the emote strip in its footer.
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

    private final class RecordingScreens: ConversationThreadScreenBuilding {
        struct Call {
            let mode: ConversationThreadMode
            let prefill: String
            let hasAccessory: Bool
        }
        private(set) var calls: [Call] = []
        let screen = UIViewController()

        func makeConversationThreadViewController(
            driver: any ConversationThreadDriving,
            mode: ConversationThreadMode,
            prefill: String,
            accessory: (any ConversationThreadAccessory)?
        ) -> UIViewController {
            calls.append(Call(mode: mode, prefill: prefill, hasAccessory: accessory != nil))
            return screen
        }
    }

    @Test func anExistingThreadIsTheFeedsScreenWithTheEmoteStrip() {
        let screens = RecordingScreens()
        let builder = ChatFeatureBuilder(repository: Stub(), threadScreens: { screens })
        let built = builder.makeConversationViewController(for: ConversationID("c1"))
        #expect(built === screens.screen)
        #expect(screens.calls.count == 1)
        #expect(screens.calls.first?.mode == .full)
        #expect(screens.calls.first?.hasAccessory == true)
    }

    @Test func aSharedLinkReachesTheFeedsScreenAsItsDraft() {
        let screens = RecordingScreens()
        let builder = ChatFeatureBuilder(repository: Stub(), threadScreens: { screens })
        _ = builder.makeDraftConversationViewController(
            with: ProfileID("them"), displayName: "Ava", prefill: "https://example.test/p/1"
        )
        #expect(screens.calls.first?.prefill == "https://example.test/p/1")
    }
}
