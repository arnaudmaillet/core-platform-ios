import CoreModels
import Foundation
import Testing
import UIKit
@testable import Chat

// A FAILED FIRST LOAD HAS A WAY OUT (#797). The inbox, the requests and the
// suggestions said "Pull to retry" — but their pull opens search. Each status
// view now carries Try Again; these pin that the action is there, that it
// reaches the view model's reload, and that the rows it brings replace it.

private struct Offline: Error {}

/// Fails the inbox until told to answer; counts every ask for its first page.
private actor FlakyInbox: ChatProviding {
    private var answers = false
    private(set) var inboxLoads = 0
    func startAnswering() { answers = true }

    func loadInbox(_ folder: InboxFolder, after pageToken: String?) async throws -> InboxPage {
        if folder == .inbox { inboxLoads += 1 }
        guard answers else { throw Offline() }
        let row: Conversation? = switch folder {
        case .inbox: conversation("a")
        case .requests: conversation("r1")
        default: nil
        }
        return InboxPage(conversations: row.map { [$0] } ?? [], nextPageToken: nil)
    }

    private func conversation(_ id: String) -> Conversation {
        Conversation(
            id: ConversationID(id), title: id, lastMessage: "hi",
            lastActivityAt: Date(timeIntervalSince1970: 0),
            otherMemberIDs: [ProfileID("peer-\(id)")], lastMessageID: "\(id)-latest"
        )
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

/// Fails until told to answer; counts every ask.
private actor FlakySuggestions: SuggestionsProviding {
    private var answers = false
    private(set) var loads = 0
    func startAnswering() { answers = true }

    func suggestions(limit: Int) async throws -> [SuggestedAccount] {
        loads += 1
        guard answers else { throw Offline() }
        return [SuggestedAccount(id: ProfileID("s1"), handle: "s1", displayName: "Name s1", avatarURL: nil, reason: .followsYou)]
    }
    func follow(_ profileID: ProfileID) async throws {}
    func unfollow(_ profileID: ProfileID) async throws {}
}

@MainActor
struct InboxFailedLoadRetryTests {
    /// Whether `condition` came to hold within `looks` short looks — a budget
    /// of looks, not of wall-clock time, so a starved runner spends none of it.
    private func settle(looks: Int = 1_000, until condition: () async -> Bool) async -> Bool {
        for _ in 0..<looks {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// The screen's status view, while it shows.
    private func statusView(of screen: UIViewController) -> InboxStatusView? {
        screen.view.subviews.compactMap { $0 as? InboxStatusView }.first { !$0.isHidden }
    }

    private static func firstView<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstView(type, in: subview) { return match }
        }
        return nil
    }

    /// The failure's Try Again, checked live: shown, enabled, and worded.
    private func tryAgain(on screen: UIViewController) async throws -> UIButton {
        try #require(await settle { statusView(of: screen) != nil }, "the failure was not shown")
        let status = try #require(statusView(of: screen))
        let button = try #require(Self.firstView(UIButton.self, in: status))
        #expect(!button.isHidden)
        #expect(button.isEnabled)
        #expect(button.configuration?.title == "Try Again")
        return button
    }

    private func screen(_ controller: UIViewController) -> UIViewController {
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        return controller
    }

    @Test func aFailedInboxOffersTryAgainWhichReloadsIt() async throws {
        let inbox = FlakyInbox()
        let catalog = InboxCatalog(repository: inbox)
        let viewModel = ConversationListViewModel(catalog: catalog)
        let screen = screen(ConversationListViewController(viewModel: viewModel))
        catalog.reload()

        let button = try await tryAgain(on: screen)
        #expect(await inbox.inboxLoads == 1)

        await inbox.startAnswering()
        button.sendActions(for: .primaryActionTriggered)

        #expect(await settle { await inbox.inboxLoads == 2 }, "Try Again did not reload the inbox")
        #expect(await settle { statusView(of: screen) == nil }, "the failure outlived the reload")
        guard case .content(let sections) = viewModel.phase else {
            Issue.record("expected content, got \(viewModel.phase)")
            return
        }
        #expect(sections.all.map(\.id.rawValue) == ["a"])
    }

    @Test func failedRequestsOfferTryAgainWhichReloadsThem() async throws {
        let inbox = FlakyInbox()
        let catalog = InboxCatalog(repository: inbox)
        let viewModel = MessageRequestsViewModel(catalog: catalog)
        let screen = screen(MessageRequestsViewController(viewModel: viewModel))
        catalog.reload()

        let button = try await tryAgain(on: screen)
        #expect(await inbox.inboxLoads == 1)

        await inbox.startAnswering()
        button.sendActions(for: .primaryActionTriggered)

        #expect(await settle { await inbox.inboxLoads == 2 }, "Try Again did not reload the requests")
        #expect(await settle { statusView(of: screen) == nil }, "the failure outlived the reload")
        guard case .content(let sections) = viewModel.phase else {
            Issue.record("expected content, got \(viewModel.phase)")
            return
        }
        #expect(sections.all.map(\.id.rawValue) == ["r1"])
    }

    @Test func failedSuggestionsOfferTryAgainWhichReloadsThem() async throws {
        let suggestions = FlakySuggestions()
        let viewModel = SuggestionsViewModel(repository: suggestions)
        let screen = screen(SuggestionsViewController(viewModel: viewModel, imagePipeline: nil))
        viewModel.loadIfNeeded()

        let button = try await tryAgain(on: screen)
        #expect(await suggestions.loads == 1)

        await suggestions.startAnswering()
        button.sendActions(for: .primaryActionTriggered)

        #expect(await settle { await suggestions.loads == 2 }, "Try Again did not reload the suggestions")
        #expect(await settle { statusView(of: screen) == nil }, "the failure outlived the reload")
        guard case .content(let models) = viewModel.phase else {
            Issue.record("expected content, got \(viewModel.phase)")
            return
        }
        #expect(models.map(\.id) == [ProfileID("s1")])
    }
}
