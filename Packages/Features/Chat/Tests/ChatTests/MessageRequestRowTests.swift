import CoreModels
import DesignSystem
import EntityStore
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Chat

/// The request row, reworked (#2088, the owner 2026-11-03): the face wears
/// the relation mark as an All row's does, the ✕ is a bare glyph, and the
/// unread count sits under Accept and the ✕ at the trailing edge.
@MainActor
@Suite(.serialized)
struct MessageRequestRowTests {
    private actor Graph: SocialGraphReading, SocialGraphWriting {
        let relation: FollowRelation
        private(set) var follows: [ProfileID] = []
        init(_ relation: FollowRelation) { self.relation = relation }
        func followRelation(to profileID: ProfileID) async throws -> FollowRelation { relation }
        func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
        func follow(_ profileID: ProfileID) async throws -> FollowOutcome {
            follows.append(profileID)
            return .following
        }
    }

    /// One request in each request folder.
    private actor OneRequestPerFolder: ChatProviding {
        func loadInbox(_ folder: InboxFolder, after pageToken: String?) async throws -> InboxPage {
            let rows = folder == .requests || folder == .hiddenRequests ? [conversation(folder == .requests ? "r1" : "h1")] : []
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

    private func model(unread: Int = 0) -> ConversationDisplayModel {
        ConversationDisplayModel(
            conversation: Conversation(
                id: ConversationID("r1"),
                title: "Ava Moreau",
                lastMessage: "hi",
                lastActivityAt: Date(timeIntervalSince1970: 0),
                otherMemberIDs: [ProfileID("peer-1")],
                lastMessageIsMine: false,
                lastMessageID: "r1-latest",
                isUnread: unread > 0,
                unreadCount: unread
            ),
            now: Date(timeIntervalSince1970: 60),
            isUnread: unread > 0,
            unreadCount: unread
        )
    }

    private func laidOut(
        _ model: ConversationDisplayModel, mark: PersonPill.Badge = .none, onFollow: (() -> Void)? = nil
    ) -> MessageRequestCell {
        let cell = MessageRequestCell(style: .default, reuseIdentifier: nil)
        cell.configure(with: model, mark: mark, onFollow: onFollow)
        let height = cell.systemLayoutSizeFitting(
            CGSize(width: 402, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        cell.frame = CGRect(x: 0, y: 0, width: 402, height: height)
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        return cell
    }

    private func frame(of view: UIView, in cell: UITableViewCell) -> CGRect {
        view.convert(view.bounds, to: cell.contentView)
    }

    private func settle(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    // MARK: - The face

    /// The face wears the mark it is given, every state, as an All row's.
    @Test(arguments: [PersonPill.Badge.none, .follow, .pending, .following, .friends])
    func theFaceWearsTheRelationMark(_ mark: PersonPill.Badge) {
        let cell = laidOut(model(), mark: mark)
        #expect(cell.relationMark == mark)
        #expect(cell.debugBadge.drawn == mark)
    }

    /// Only the "+" calls the follow, and a touch on it is the badge's, not
    /// the row's.
    @Test func onlyThePlusCallsTheFollow() {
        var follows = 0
        let cell = laidOut(model(), mark: .follow, onFollow: { follows += 1 })
        let badge = cell.debugBadge
        let centre = badge.convert(CGPoint(x: badge.bounds.midX, y: badge.bounds.midY), to: cell)
        #expect(cell.hitTest(centre, with: nil) === badge)
        badge.sendActions(for: .primaryActionTriggered)
        #expect(follows == 1)
        #expect(cell.contentView.accessibilityCustomActions?.first?.name == "Follow")
        cell.setRelationMark(.following, animated: false)
        badge.sendActions(for: .primaryActionTriggered)
        #expect(follows == 1, "a state mark followed")
        #expect(cell.hitTest(centre, with: nil) !== badge)
        #expect(cell.contentView.accessibilityCustomActions == nil)
    }

    // MARK: - The ✕

    /// The Suggestions row's ✕: a bare glyph, no bubble, the tertiary ink.
    @Test func theDeclineIsABareGlyph() {
        let cell = laidOut(model())
        let decline = cell.debugDismissButton
        #expect(decline.style == .glyph)
        #expect(decline.content.symbol == "xmark")
        #expect(decline.inkColor == .tertiaryLabel)
        #expect(decline.accessibilityLabel == "Decline request from Ava Moreau")
    }

    // MARK: - The count

    /// Under Accept and the ✕, aligned to the trailing edge; "99+" past 99.
    @Test(arguments: [3, 12, 120])
    func theCountSitsUnderTheActions(_ count: Int) {
        let cell = laidOut(model(unread: count))
        let pill = cell.debugUnreadPill
        #expect(pill.shownText == UnreadCountPill.text(for: count))
        let pillFrame = frame(of: pill, in: cell)
        let accept = frame(of: cell.debugAcceptButton, in: cell)
        let decline = frame(of: cell.debugDismissButton, in: cell)
        #expect(pillFrame.minY >= accept.maxY, "the count is not under Accept")
        #expect(abs(pillFrame.maxX - decline.maxX) < 0.5, "the count is not on the trailing edge")
        #expect(contentLabel(cell).contains("\(count) unread"))
    }

    /// Hidden at zero and on a read request — and the actions don't move.
    @Test func noCountWhenReadAndNothingMoves() {
        let read = laidOut(model())
        let unread = laidOut(model(unread: 4))
        #expect(read.debugUnreadPill.shownText == nil)
        #expect(read.bounds.height == unread.bounds.height, "a count changed the row's height")
        #expect(frame(of: read.debugAcceptButton, in: read) == frame(of: unread.debugAcceptButton, in: unread))
        #expect(!contentLabel(read).contains("unread"))
    }

    /// At the default text size the row keeps the shared pitch: the same
    /// height as an All row, measured the same way.
    @Test func theRowKeepsTheSharedPitch() {
        let request = laidOut(model(unread: 2))
        let conversation = ConversationCell(style: .default, reuseIdentifier: nil)
        conversation.configure(with: model(unread: 2))
        let allRow = conversation.systemLayoutSizeFitting(
            CGSize(width: 402, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        #expect(request.bounds.height == allRow, "the row grew: \(request.bounds.height) against an All row's \(allRow)")
        #expect(MessageRequestCell.actionColumnHeight(accept: request.debugAcceptButton) <= PersonRowMetrics.rowHeight - 2 * Spacing.xs)
    }

    private func contentLabel(_ cell: MessageRequestCell) -> String { cell.contentView.accessibilityLabel ?? "" }

    // MARK: - The screens

    /// Both request screens get the relations: their rows' faces take the
    /// relation the graph answers.
    @Test(arguments: [InboxFolder.requests, .hiddenRequests])
    func theRequestScreensWearTheMark(_ folder: InboxFolder) async throws {
        let graph = Graph(.notFollowing)
        let relations = InboxRelations(entities: EntityStore(), reader: graph, writer: graph)
        let catalog = InboxCatalog(repository: OneRequestPerFolder())
        let screen = MessageRequestsViewController(
            viewModel: MessageRequestsViewModel(catalog: catalog, folder: folder), relations: relations
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        screen.loadViewIfNeeded()
        screen.view.frame = window.bounds
        window.addSubview(screen.view)
        defer { window.isHidden = true }
        catalog.reload()
        func firstCell() -> MessageRequestCell? {
            guard let table = screen.view.subviews.compactMap({ $0 as? UITableView }).first else { return nil }
            table.layoutIfNeeded()
            return table.visibleCells.compactMap { $0 as? MessageRequestCell }.first
        }
        try #require(await settle { firstCell() != nil }, "no request row")
        try #require(await settle { firstCell()?.relationMark == .follow }, "the face wears no mark")
    }
}
