import CoreModels
import DesignSystem
import Foundation
import Testing
import UIKit
@testable import Chat

// THE INBOX'S ROW ACTIONS ARE UIKIT'S SYSTEM BUTTON (#885). The Requests
// rows' Accept and Decline and the Suggestions rows' Follow and ✕ are the
// shared `RowActionButton`: system capsules, UIKit's own press, Follow ⇄
// Following cross-faded. These pin the states per tab and that every action
// still lands through the button, optimistic and rolled back as before.

private struct Refused: Error {}

/// Two requests, nothing else.
private actor TwoRequests: ChatProviding {
    func loadInbox(_ folder: InboxFolder, after pageToken: String?) async throws -> InboxPage {
        let rows = folder == .requests ? [conversation("r1"), conversation("r2")] : []
        return InboxPage(conversations: rows, nextPageToken: nil)
    }

    private func conversation(_ id: String) -> Conversation {
        Conversation(
            id: ConversationID(id), title: "Name \(id)", lastMessage: "hi",
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

/// One suggestion; follows succeed or are refused.
private actor OneSuggestion: SuggestionsProviding {
    private var refuses = false
    private(set) var followed: [ProfileID] = []
    private(set) var unfollowed: [ProfileID] = []
    func setRefuses(_ refuses: Bool) { self.refuses = refuses }

    func suggestions(limit: Int) async throws -> [SuggestedAccount] {
        [SuggestedAccount(id: ProfileID("s1"), handle: "s1", displayName: "Name s1", avatarURL: nil, reason: .followsYou)]
    }
    func follow(_ profileID: ProfileID) async throws {
        if refuses { throw Refused() }
        followed.append(profileID)
    }
    func unfollow(_ profileID: ProfileID) async throws {
        if refuses { throw Refused() }
        unfollowed.append(profileID)
    }
}

@MainActor
struct InboxRowActionButtonTests {
    /// Whether `condition` came to hold within `looks` short looks — a budget
    /// of looks, not of wall-clock time, so a starved runner spends none of it.
    private func settle(looks: Int = 1_000, until condition: () async -> Bool) async -> Bool {
        for _ in 0..<looks {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    private static func firstView<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstView(type, in: subview) { return match }
        }
        return nil
    }

    /// The screen in a window, so its rows are real cells and a change on
    /// one can animate.
    private func onScreen(_ controller: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = true
        controller.loadViewIfNeeded()
        controller.view.frame = window.bounds
        window.addSubview(controller.view)
        controller.view.layoutIfNeeded()
        return window
    }

    /// The `row`th row on screen, top down, whatever section it is in.
    private func cell<T: UITableViewCell>(_ type: T.Type, row: Int, in controller: UIViewController) -> T? {
        guard let table = Self.firstView(UITableView.self, in: controller.view) else { return nil }
        table.layoutIfNeeded()
        let rows = (table.indexPathsForVisibleRows ?? []).sorted()
        guard rows.indices.contains(row) else { return nil }
        return table.cellForRow(at: rows[row]) as? T
    }

    /// The touch-down handlers wired to a control: one per press effect.
    private func touchDownHandlers(_ control: UIControl) -> Int {
        var count = 0
        control.enumerateEventHandlers { _, _, event, _ in
            if event.contains(.touchDown) { count += 1 }
        }
        return count
    }

    private func expectUIKitsOwnPress(_ button: UIButton, _ name: String) {
        #expect(PressFeedback.attached(to: button) == nil, "\(name) carries a custom press")
        #expect(touchDownHandlers(button) == 0, "\(name) has something wired to touch-down")
    }

    // MARK: - Suggestions

    private func suggestion(following: Bool, id: String = "s1") -> SuggestionDisplayModel {
        SuggestionDisplayModel(
            account: SuggestedAccount(id: ProfileID(id), handle: id, displayName: "Name \(id)", avatarURL: nil, reason: .followsYou),
            isFollowing: following
        )
    }

    /// Follow is the filled system capsule, Following the grey one, each
    /// labelled with the person; the ✕ is the same button.
    @Test func suggestionRowsShowFollowAndFollowingAsSystemCapsules() {
        let cell = SuggestionCell(style: .default, reuseIdentifier: nil)
        cell.configure(with: suggestion(following: false), imagePipeline: nil)
        #expect(cell.debugFollowButton.requestedConfiguration == RowActionButton.configuration(title: "Follow", prominence: .prominent))
        #expect(cell.debugFollowButton.configuration?.title == "Follow")
        #expect(cell.debugFollowButton.accessibilityLabel == "Follow Name s1")

        cell.configure(with: suggestion(following: true), imagePipeline: nil)
        #expect(cell.debugFollowButton.requestedConfiguration == RowActionButton.configuration(title: "Following", prominence: .secondary))
        #expect(cell.debugFollowButton.configuration?.title == "Following")
        #expect(cell.debugFollowButton.accessibilityLabel == "Unfollow Name s1")

        expectUIKitsOwnPress(cell.debugFollowButton, "Follow")
        expectUIKitsOwnPress(cell.debugDismissButton, "the ✕")
    }

    /// The same person flipping cross-fades; a reused row showing someone
    /// else takes their state at once.
    @Test func aSuggestionFlipCrossFadesOnlyForTheSamePerson() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = true
        let cell = SuggestionCell(style: .default, reuseIdentifier: nil)
        cell.frame = CGRect(x: 0, y: 0, width: 390, height: 76)
        window.addSubview(cell)
        cell.configure(with: suggestion(following: false), imagePipeline: nil)
        cell.layoutIfNeeded()
        #expect(!cell.debugFollowButton.isTransitioning, "a first state faded in")

        cell.configure(with: suggestion(following: true), imagePipeline: nil)
        #expect(cell.debugFollowButton.isTransitioning, "Follow → Following did not cross-fade")

        cell.prepareForReuse()
        cell.configure(with: suggestion(following: false, id: "s2"), imagePipeline: nil)
        #expect(!cell.debugFollowButton.isTransitioning, "a reused row kept the last person's fade")
        cell.layoutIfNeeded()
        cell.configure(with: suggestion(following: true, id: "s3"), imagePipeline: nil)
        #expect(!cell.debugFollowButton.isTransitioning, "a different person's state faded in")
        #expect(cell.debugFollowButton.configuration?.title == "Following")
    }

    /// Tapping Follow flips the row at once and reaches the server; tapping
    /// Following unfollows; a refused follow puts Follow back.
    @Test func suggestionsFollowButtonFollowsOptimisticallyAndRollsBack() async throws {
        let repository = OneSuggestion()
        let viewModel = SuggestionsViewModel(repository: repository)
        let screen = SuggestionsViewController(viewModel: viewModel, imagePipeline: nil)
        let window = onScreen(screen)
        defer { window.isHidden = true }
        screen.surfaceDidBecomeActive()
        try #require(await settle { cell(SuggestionCell.self, row: 0, in: screen) != nil }, "no suggestion row")

        func button() -> RowActionButton? { cell(SuggestionCell.self, row: 0, in: screen)?.debugFollowButton }
        #expect(button()?.configuration?.title == "Follow")

        button()?.sendActions(for: .primaryActionTriggered)
        // Before any await: the optimistic row.
        #expect(button()?.configuration?.title == "Following", "the row waited for the server")
        #expect(await settle { await repository.followed == [ProfileID("s1")] }, "the follow never left")

        button()?.sendActions(for: .primaryActionTriggered)
        #expect(button()?.configuration?.title == "Follow")
        #expect(await settle { await repository.unfollowed == [ProfileID("s1")] }, "the unfollow never left")

        await repository.setRefuses(true)
        button()?.sendActions(for: .primaryActionTriggered)
        #expect(button()?.configuration?.title == "Following")
        #expect(await settle { button()?.configuration?.title == "Follow" }, "a refused follow kept Following")
        #expect(!viewModel.isFollowing(ProfileID("s1")))
    }

    /// The ✕ takes the suggestion away.
    @Test func suggestionsDismissButtonRemovesTheRow() async throws {
        let viewModel = SuggestionsViewModel(repository: OneSuggestion())
        let screen = SuggestionsViewController(viewModel: viewModel, imagePipeline: nil)
        let window = onScreen(screen)
        defer { window.isHidden = true }
        screen.surfaceDidBecomeActive()
        try #require(await settle { cell(SuggestionCell.self, row: 0, in: screen) != nil }, "no suggestion row")
        let row = try #require(cell(SuggestionCell.self, row: 0, in: screen))

        row.debugDismissButton.sendActions(for: .primaryActionTriggered)
        #expect(viewModel.phase == .empty, "the ✕ did not dismiss: \(viewModel.phase)")
    }

    // MARK: - Requests

    /// Accept is the filled system capsule, Decline the grey ✕ — both the
    /// shared button, both with UIKit's own press.
    @Test func requestRowsShowAcceptAndDeclineAsSystemButtons() {
        let cell = MessageRequestCell(style: .default, reuseIdentifier: nil)
        #expect(cell.debugAcceptButton.requestedConfiguration == RowActionButton.configuration(title: "Accept", prominence: .prominent))
        let decline = cell.debugDismissButton.requestedConfiguration
        #expect(decline?.image != nil && decline?.title == nil, "Decline is not the ✕")
        #expect(decline?.cornerStyle == .capsule)
        expectUIKitsOwnPress(cell.debugAcceptButton, "Accept")
        expectUIKitsOwnPress(cell.debugDismissButton, "Decline")
    }

    /// Accept on a row moves the request to All; Decline on the next takes it
    /// out of the inbox — both at once, from the row's buttons.
    @Test func requestButtonsAcceptAndDecline() async throws {
        let catalog = InboxCatalog(repository: TwoRequests())
        let viewModel = MessageRequestsViewModel(catalog: catalog)
        let screen = MessageRequestsViewController(viewModel: viewModel)
        let window = onScreen(screen)
        defer { window.isHidden = true }
        var snapshot: InboxCatalog.Snapshot?
        let token = catalog.observe { snapshot = $0 }
        defer { _ = token }
        catalog.reload()
        try #require(await settle { cell(MessageRequestCell.self, row: 1, in: screen) != nil }, "no request rows")

        func requestIDs() -> [String] {
            guard case .content(let sections) = viewModel.phase else { return [] }
            return sections.all.map(\.id.rawValue)
        }
        #expect(requestIDs() == ["r1", "r2"])
        let first = try #require(cell(MessageRequestCell.self, row: 0, in: screen))
        first.debugAcceptButton.sendActions(for: .primaryActionTriggered)
        #expect(requestIDs() == ["r2"], "Accept did not take the request off Requests")
        #expect(snapshot?.active.map(\.id.rawValue) == ["r1"], "Accept did not land the request in All")

        let next = try #require(cell(MessageRequestCell.self, row: 0, in: screen))
        next.debugDismissButton.sendActions(for: .primaryActionTriggered)
        #expect(viewModel.phase == .empty, "Decline did not take the request away: \(viewModel.phase)")
        #expect(snapshot?.active.map(\.id.rawValue) == ["r1"], "Decline moved the request to All")
    }
}
