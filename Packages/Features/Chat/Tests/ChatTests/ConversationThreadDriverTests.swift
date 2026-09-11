import CoreModels
import FeedInterface
import Foundation
import Testing
@testable import Chat

/// The driver is a pass-through: Feed's screen must see exactly what the old
/// screen saw, spelled in its own values. These pin the spelling — messages
/// and quotes, who the viewer is signed as, the peer — and that every action
/// still reaches the view model that owns it.
@MainActor
struct ConversationThreadDriverTests {
    private actor Stub: ChatProviding {
        var messages: [ChatMessage]
        private(set) var sentBodies: [String] = []

        init(messages: [ChatMessage]) { self.messages = messages }

        func viewerProfileID() async throws -> ProfileID { ProfileID("me") }
        func loadConversations() async throws -> [Conversation] {
            [Conversation(
                id: ConversationID("c1"), title: "Ava", lastMessage: "hi",
                lastActivityAt: Date(timeIntervalSince1970: 0), otherMemberIDs: [ProfileID("them")]
            )]
        }
        func loadMessages(in conversationID: ConversationID) async throws -> [ChatMessage] { messages }
        func send(_ body: String, to conversationID: ConversationID, replyingTo replyToID: String?) async throws -> ChatMessage {
            sentBodies.append(body)
            let message = ChatMessage(
                id: "sent", senderID: ProfileID("me"), body: body,
                createdAt: Date(timeIntervalSince1970: 300), isMine: true, replyToID: replyToID
            )
            messages.append(message)
            return message
        }
        func markRead(_ conversationID: ConversationID, upTo messageID: String) async throws {}
        func directConversation(with profileID: ProfileID) async throws -> ConversationID { ConversationID("dm") }
    }

    private static let seed = [
        ChatMessage(id: "m1", senderID: ProfileID("them"), body: "Are you around?",
                    createdAt: Date(timeIntervalSince1970: 100), isMine: false),
        ChatMessage(id: "m2", senderID: ProfileID("me"), body: "Yes!",
                    createdAt: Date(timeIntervalSince1970: 200), isMine: true, replyToID: "m1"),
    ]

    private struct Harness {
        let stub: Stub
        let driver: ConversationThreadDriver
        var phases: [ConversationThreadPhase] = []
    }

    private func makeDriver() -> (Stub, ConversationThreadDriver) {
        let stub = Stub(messages: Self.seed)
        let viewModel = ConversationViewModel(conversationID: ConversationID("c1"), repository: stub)
        return (stub, ConversationThreadDriver(viewModel: viewModel, viewer: stub, avatars: nil))
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func messagesArriveOldestFirstWithTheirQuotesResolved() async throws {
        let (_, driver) = makeDriver()
        var last: [ConversationThreadMessage] = []
        driver.onPhaseChange = { if case .content(let messages) = $0 { last = messages } }
        driver.viewDidLoad()
        // The quote is re-signed once the peer's name resolves.
        await settle { last.last?.quote?.author == "Ava" }

        #expect(last.map(\.id) == ["m1", "m2"])
        let quote = try #require(last.last?.quote)
        #expect(quote.messageID == "m1")
        #expect(quote.author == "Ava")
        #expect(quote.snippet == "Are you around?")
        #expect(last.first?.quote == nil)
    }

    @Test func theViewerIsSignedAsYouFromTheFirstFrameThenGainsTheirID() async {
        let (_, driver) = makeDriver()
        var viewers: [ConversationThreadPerson] = []
        driver.onViewerChange = { viewers.append($0) }
        driver.viewDidLoad()
        #expect(viewers.first?.name == "You", "signed before any fetch")
        await settle { viewers.last?.id != nil }
        #expect(viewers.last?.id == ProfileID("me"))
        #expect(viewers.allSatisfy { $0.name == "You" })
    }

    @Test func thePeerArrivesWithTheirNameAndID() async {
        let (_, driver) = makeDriver()
        var peer: ConversationThreadPerson?
        driver.onPeerChange = { peer = $0 }
        driver.viewDidLoad()
        await settle { peer?.id != nil && peer?.name.isEmpty == false }
        #expect(peer?.name == "Ava")
        #expect(peer?.id == ProfileID("them"))
    }

    @Test func actionsReachTheViewModel() async {
        let (stub, driver) = makeDriver()
        var last: [ConversationThreadMessage] = []
        var notices: [String] = []
        var draft: ConversationThreadReplyDraft?
        driver.onPhaseChange = { if case .content(let messages) = $0 { last = messages } }
        driver.onActionNotice = { title, _ in notices.append(title) }
        driver.onReplyStateChange = { draft = $0 }
        driver.viewDidLoad()
        await settle { last.count == 2 }

        driver.beginReply(to: "m1")
        #expect(draft?.messageID == "m1")
        driver.cancelReply()
        #expect(draft == nil)

        driver.forward("m1")
        #expect(notices == ["Forward"])

        driver.delete("m1")
        #expect(last.map(\.id) == ["m2"])

        driver.send("On my way")
        await settle { last.last?.id == "sent" }
        #expect(await stub.sentBodies == ["On my way"])
        #expect(last.last?.body == "On my way")
    }
}
