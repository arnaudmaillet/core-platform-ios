import CoreModels
import DesignSystem
import Foundation
import Testing
import UIKit
@testable import Chat

/// An inbox that never answers (#1770): after 10 s the screen says "Taking
/// longer than usual" in place of its bones, and Try Again asks again.
@MainActor
struct InboxTakingLongerTests {
    /// Never answers; counts every ask for the inbox's first page.
    private actor SilentInbox: ChatProviding {
        private(set) var inboxLoads = 0
        func loadInbox(_ folder: InboxFolder, after pageToken: String?) async throws -> InboxPage {
            if folder == .inbox { inboxLoads += 1 }
            try await Task.sleep(for: .seconds(3600))
            return InboxPage(conversations: [], nextPageToken: nil)
        }
        func viewerProfileID() async throws -> ProfileID { ProfileID("me") }
        func loadConversations() async throws -> [Conversation] { [] }
        func loadMessages(in conversationID: ConversationID) async throws -> [ChatMessage] { [] }
        func send(_ body: String, to conversationID: ConversationID, replyingTo replyToID: String?) async throws -> ChatMessage {
            ChatMessage(id: "m", senderID: ProfileID("me"), body: body, createdAt: Date(), isMine: true)
        }
        func markRead(_ conversationID: ConversationID, upTo messageID: String) async throws {}
        func directConversation(with profileID: ProfileID) async throws -> ConversationID { ConversationID("dm") }
    }

    private func find<T: UIView>(_ type: T.Type, in view: UIView, where match: (T) -> Bool) -> T? {
        if let found = view as? T, match(found), !found.isHidden { return found }
        for subview in view.subviews where !subview.isHidden {
            if let found = find(type, in: subview, where: match) { return found }
        }
        return nil
    }

    @Test func anInboxThatNeverAnswersOffersTryAgain() async throws {
        let time = ManualLoadingClock()
        let inbox = SilentInbox()
        let catalog = InboxCatalog(repository: inbox)
        let screen = ConversationListViewController(viewModel: ConversationListViewModel(catalog: catalog))
        screen.skeletonClock = time.clock
        screen.loadViewIfNeeded()
        screen.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        screen.view.layoutIfNeeded()
        catalog.reload()
        for _ in 0..<1_000 where await inbox.inboxLoads == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }

        time.advance(LoadingTiming.takingLonger)
        #expect(find(UILabel.self, in: screen.view) { $0.text == TakingLongerCopy.title } != nil,
                "no \"Taking longer\" on the inbox")
        let retry = try #require(find(UIButton.self, in: screen.view) {
            $0.configuration?.title == TakingLongerCopy.action
        })
        retry.sendActions(for: .primaryActionTriggered)
        for _ in 0..<1_000 where await inbox.inboxLoads < 2 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await inbox.inboxLoads == 2, "Try Again did not ask for the inbox again")
    }
}
