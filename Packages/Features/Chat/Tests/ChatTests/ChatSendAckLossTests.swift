import AuthInterface
import Connect
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Chat

/// ⚠️ **A LOST ANSWER IS NOT A LOST WRITE (#795).** chat.v1 can store a
/// message and its answer never arrive: the client sees a failure, the viewer
/// taps the failed bubble, and without a key the conversation carries the
/// message twice. These lose the answer on purpose, against the mock BFF —
/// and answer ABORTED, which is what a repeat gets while the first send is
/// still in flight.
@MainActor
struct ChatSendAckLossTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    /// Hands every call to the mock BFF. While `losses` lasts, a SendMessage
    /// is applied and its answer swapped for a transport failure: the server
    /// did it, the client never heard. While `aborts` lasts, a SendMessage
    /// is NOT applied and is answered ABORTED, as chat.v1 answers a repeat
    /// while the first send is still in flight (CHT-1013).
    private final class FaultyRelay: HTTPClientInterface, @unchecked Sendable {
        private let bff: MockBFF
        private let lock = NSLock()
        private var losses: Int
        private var aborts: Int
        private let abortMessage: String
        private var sends = 0

        init(_ bff: MockBFF, losing losses: Int, aborting aborts: Int, abortMessage: String) {
            self.bff = bff
            self.losses = losses
            self.aborts = aborts
            self.abortMessage = abortMessage
        }

        /// Every SendMessage that reached the relay, whatever its answer.
        var sendCount: Int { lock.withLock { sends } }

        private enum Fault { case none, lose, abort }

        @discardableResult
        func unary(
            request: HTTPRequest<Data?>,
            onMetrics: @escaping @Sendable (HTTPMetrics) -> Void,
            onResponse: @escaping @Sendable (HTTPResponse) -> Void
        ) -> Cancelable {
            let isSend = request.url.path.hasSuffix("/SendMessage")
            let fault: Fault = !isSend ? .none : lock.withLock {
                sends += 1
                if aborts > 0 {
                    aborts -= 1
                    return .abort
                }
                if losses > 0 {
                    losses -= 1
                    return .lose
                }
                return .none
            }
            switch fault {
            case .none:
                return bff.unary(request: request, onMetrics: onMetrics, onResponse: onResponse)
            case .lose:
                return bff.unary(request: request, onMetrics: onMetrics) { _ in
                    onResponse(Self.failure(ConnectError(code: .unavailable, message: "the answer was lost")))
                }
            case .abort:
                onResponse(Self.failure(ConnectError(code: .aborted, message: abortMessage)))
                return Cancelable(cancel: {})
            }
        }

        private static func failure(_ error: ConnectError) -> HTTPResponse {
            HTTPResponse(code: error.code, headers: [:], message: nil, trailers: [:], error: error, tracingInfo: nil)
        }

        func stream(request: HTTPRequest<Data?>, responseCallbacks: ResponseCallbacks) -> RequestCallbacks<Data> {
            bff.stream(request: request, responseCallbacks: responseCallbacks)
        }
    }

    private struct Rig {
        let repository: ChatRepository
        let relay: FaultyRelay
        let blobs: MockBlobStore
    }

    /// What chat.v1 says when a send with the key is in flight: its error's
    /// text, the code kept in the service's logs.
    static let inFlight = "a send with this idempotency key is in flight in conversation conv-1"

    private func rig(
        losing losses: Int = 0, aborting aborts: Int = 0, waits: Int = 2, abortMessage: String = inFlight
    ) -> Rig {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        let blobs = MockBlobStore()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockChatService(dataset: dataset).register(on: bff)
        MockMediaService(store: blobs).register(on: bff)
        let relay = FaultyRelay(bff, losing: losses, aborting: aborts, abortMessage: abortMessage)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: relay)
        let repository = ChatRepository(
            chatClient: Chat_V1_ChatServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: Session(),
            mediaUploader: MediaAssetUploader(
                mediaClient: Media_V1_MediaServiceClient(client: client),
                transport: MockMediaUploadTransport(store: blobs),
                resolveMaxAttempts: 3, resolvePollSeconds: 0.01
            ),
            // No wall clock: the waits are there, and take no time.
            inFlightRetryDelays: Array(repeating: .zero, count: waits)
        )
        return Rig(repository: repository, relay: relay, blobs: blobs)
    }

    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private static func solid() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
    }

    // MARK: - The repository

    /// The retry goes under the same key, and the mock answers it with the
    /// message it already stored: one message, not two, and the same id.
    @Test func aRetriedTextAfterALostAnswerIsStoredOnce() async throws {
        let rig = rig(losing: 1)
        let conversation = ConversationID("conv-1")
        let key = IdempotencyKey.mint()

        await #expect(throws: ChatError.self) {
            _ = try await rig.repository.send("Lost answer", to: conversation, replyingTo: nil, idempotencyKey: key)
        }
        let sent = try await rig.repository.send("Lost answer", to: conversation, replyingTo: nil, idempotencyKey: key)

        let history = try await rig.repository.loadMessages(in: conversation)
        #expect(history.filter { $0.body == "Lost answer" }.count == 1, "the retry stored the message twice")
        #expect(history.last?.id == sent.id, "the retry was not answered with the stored message")
    }

    /// The other half: another key is another message. Without this, a mock
    /// that answered every send with the first message would pass above.
    @Test func anotherKeyIsAnotherMessage() async throws {
        let rig = rig()
        let conversation = ConversationID("conv-1")

        let first = try await rig.repository.send("Twice", to: conversation, replyingTo: nil, idempotencyKey: IdempotencyKey.mint())
        let second = try await rig.repository.send("Twice", to: conversation, replyingTo: nil, idempotencyKey: IdempotencyKey.mint())

        #expect(first.id != second.id)
        let history = try await rig.repository.loadMessages(in: conversation)
        #expect(history.filter { $0.body == "Twice" }.count == 2)
    }

    /// ⚠️ ABORTED IS "NOT YET": the first send is still in flight on the
    /// server, so the repeat waits and asks again under the same key — and
    /// the bubble never fails for it.
    @Test func aSendAbortedWhileItsFirstIsInFlightIsAskedAgain() async throws {
        let rig = rig(aborting: 2, waits: 2)
        let conversation = ConversationID("conv-1")

        let sent = try await rig.repository.send("In flight", to: conversation, replyingTo: nil, idempotencyKey: IdempotencyKey.mint())

        #expect(rig.relay.sendCount == 3)
        let history = try await rig.repository.loadMessages(in: conversation)
        #expect(history.filter { $0.body == "In flight" }.map(\.id) == [sent.id])
    }

    /// Past the last wait, ABORTED fails like any other failure — and the
    /// bubble's own retry, under the same key, lands the message once.
    @Test func aSendStillAbortedAfterTheLastWaitFailsAndItsRetryLands() async throws {
        let rig = rig(aborting: 2, waits: 1)
        let conversation = ConversationID("conv-1")
        let key = IdempotencyKey.mint()

        await #expect(throws: ChatError.self) {
            _ = try await rig.repository.send("Later", to: conversation, replyingTo: nil, idempotencyKey: key)
        }
        #expect(rig.relay.sendCount == 2, "the repeat did not wait and ask again")
        _ = try await rig.repository.send("Later", to: conversation, replyingTo: nil, idempotencyKey: key)

        let history = try await rig.repository.loadMessages(in: conversation)
        #expect(history.filter { $0.body == "Later" }.count == 1)
    }

    /// Only the in-flight ABORTED is waited out: any other is a failure.
    @Test func anotherAbortedIsNotAskedAgain() async throws {
        let rig = rig(aborting: 1, waits: 2, abortMessage: "transaction aborted")

        await #expect(throws: ChatError.self) {
            _ = try await rig.repository.send("Other", to: ConversationID("conv-1"), replyingTo: nil, idempotencyKey: IdempotencyKey.mint())
        }
        #expect(rig.relay.sendCount == 1)
    }

    /// Without a key there is nothing to wait for: ABORTED is a failure.
    @Test func aKeylessSendIsNotAskedAgain() async throws {
        let rig = rig(aborting: 1, waits: 2)

        await #expect(throws: ChatError.self) {
            _ = try await rig.repository.send("No key", to: ConversationID("conv-1"), replyingTo: nil)
        }
        #expect(rig.relay.sendCount == 1)
    }

    /// The send step of a photo is keyed too: its answer lost, the retry
    /// replays the upload AND the send — one asset, one message.
    @Test func aRetriedPhotoAfterALostSendAnswerIsOneAssetAndOneMessage() async throws {
        let rig = rig(losing: 1)
        let conversation = ConversationID("conv-1")
        let key = IdempotencyKey.mint()
        let photo = Self.solid()
        let before = try await rig.repository.loadMessages(in: conversation).count

        await #expect(throws: ChatError.self) {
            _ = try await rig.repository.send(
                media: .image(photo), caption: "", to: conversation, replyingTo: nil, idempotencyKey: key
            )
        }
        let sent = try await rig.repository.send(
            media: .image(photo), caption: "", to: conversation, replyingTo: nil, idempotencyKey: key
        )

        let history = try await rig.repository.loadMessages(in: conversation)
        #expect(history.count == before + 1, "the retry sent the photo twice")
        #expect(history.last?.id == sent.id)
        #expect(rig.blobs.assetCount == 1, "the retry uploaded the photo twice")
    }

    /// A caller's key of any shape still names one send: what the contract
    /// refuses as it stands goes out as its digest, and repeats as one.
    @Test func aKeyTheContractRefusesAsItStandsStillNamesOneSend() async throws {
        let rig = rig()
        let conversation = ConversationID("conv-1")

        let first = try await rig.repository.send("Short key", to: conversation, replyingTo: nil, idempotencyKey: "k")
        let again = try await rig.repository.send("Short key", to: conversation, replyingTo: nil, idempotencyKey: "k")

        #expect(first.id == again.id)
        #expect(IdempotencyKey.isValid(IdempotencyKey.wire("k")))
        #expect(IdempotencyKey.wire("k") == IdempotencyKey.wire("k"))
        #expect(IdempotencyKey.wire("") == "")
    }

    // MARK: - The thread

    /// End to end: the thread's text is stored, its answer lost, the bubble
    /// fails; the viewer's retry goes under the bubble's key, and the
    /// conversation carries the message once.
    @Test func aRetriedBubbleAfterALostAnswerShowsAndStoresOneMessage() async throws {
        let rig = rig(losing: 1)
        let conversation = ConversationID("conv-1")
        let viewModel = ConversationViewModel(conversationID: conversation, repository: rig.repository)
        var phases: [ConversationViewModel.Phase] = []
        viewModel.onPhaseChange = { phases.append($0) }
        viewModel.viewDidLoad()
        #expect(await settle { if case .content = phases.last { true } else { false } })

        viewModel.send("From the thread")
        guard case .content(let pending) = phases.last, let bubble = pending.last else {
            Issue.record("no pending bubble"); return
        }
        #expect(await settle {
            if case .content(let models) = phases.last { models.last?.delivery == .failed } else { false }
        }, "a lost answer did not fail the bubble")

        viewModel.retry(bubble.id)
        #expect(await settle {
            if case .content(let models) = phases.last { models.last?.delivery == .sent } else { false }
        }, "the retry did not deliver")

        guard case .content(let shown) = phases.last else { return }
        #expect(shown.filter { $0.body == "From the thread" }.count == 1)
        let history = try await rig.repository.loadMessages(in: conversation)
        #expect(history.filter { $0.body == "From the thread" }.count == 1, "the retry stored the message twice")
    }
}

/// The first send of a text lands and its answer is lost; a later load
/// draws it; a repeat under the same key is answered with it, as chat.v1
/// answers a replay.
private actor LandedOnceProvider: ChatProviding {
    private var stored: [ChatMessage] = []
    private var keys: [String: ChatMessage] = [:]

    func viewerProfileID() async throws -> ProfileID { ProfileID("me") }
    func loadConversations() async throws -> [Conversation] { [] }
    func loadMessages(in conversationID: ConversationID) async throws -> [ChatMessage] { stored }
    func send(_ body: String, to conversationID: ConversationID, replyingTo replyToID: String?) async throws -> ChatMessage {
        throw ChatError.transport(message: "keyless")
    }
    func send(
        _ body: String, to conversationID: ConversationID, replyingTo replyToID: String?, idempotencyKey: String
    ) async throws -> ChatMessage {
        if let first = keys[idempotencyKey] { return first }
        let message = ChatMessage(id: "t1", senderID: ProfileID("me"), body: body, createdAt: Date(), isMine: true)
        keys[idempotencyKey] = message
        stored.append(message)
        throw ChatError.transport(message: "the answer was lost")
    }
    func markRead(_ conversationID: ConversationID, upTo messageID: String) async throws {}
    func directConversation(with profileID: ProfileID) async throws -> ConversationID { ConversationID("c") }
}

@MainActor
struct ChatReplayOnScreenTests {
    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// ⚠️ A REPLAY CAN ANSWER A MESSAGE ALREADY ON SCREEN: the first send
    /// landed and failed, a reload drew it as `t1`, and the retry under the
    /// same key is answered `t1` — the thread holds it once, not twice (a
    /// second row with one id would crash the diffable snapshot).
    @Test func aRetryAnsweredWithAMessageAlreadyDrawnShowsItOnce() async throws {
        let viewModel = ConversationViewModel(conversationID: ConversationID("c"), repository: LandedOnceProvider())
        var phases: [ConversationViewModel.Phase] = []
        viewModel.onPhaseChange = { phases.append($0) }
        viewModel.viewDidLoad()
        #expect(await settle { if case .content = phases.last { true } else { false } })

        viewModel.send("hello")
        guard case .content(let pending) = phases.last, let bubble = pending.last else {
            Issue.record("no pending bubble"); return
        }
        #expect(await settle {
            if case .content(let models) = phases.last { models.last?.delivery == .failed } else { false }
        })
        viewModel.refresh()
        #expect(await settle {
            if case .content(let models) = phases.last { models.contains { $0.id == "t1" } } else { false }
        }, "the reload did not draw the landed message")

        viewModel.retry(bubble.id)
        #expect(await settle {
            if case .content(let models) = phases.last { !models.contains { $0.id == bubble.id } } else { false }
        }, "the retry did not deliver")
        guard case .content(let shown) = phases.last else { return }
        #expect(shown.filter { $0.id == "t1" }.count == 1, "the replay drew the message twice")
        #expect(shown.filter { $0.body == "hello" }.count == 1)
    }
}
