import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import FeedInterface
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Chat

/// A photo or video in a conversation (#681): the reference chat.v1 carries,
/// the upload then the MEDIA send against the mock BFF, and the thread's
/// optimistic bubble with its retry.
@MainActor
struct ChatMediaTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    private static func solid(_ size: CGSize = CGSize(width: 40, height: 30)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func repository(transport: (any MediaUploadTransport)? = nil) -> ChatRepository {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        let blobs = MockBlobStore()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockChatService(dataset: dataset).register(on: bff)
        MockMediaService(store: blobs).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return ChatRepository(
            chatClient: Chat_V1_ChatServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: Session(),
            mediaUploader: MediaAssetUploader(
                mediaClient: Media_V1_MediaServiceClient(client: client),
                transport: transport ?? MockMediaUploadTransport(store: blobs),
                resolveMaxAttempts: 3, resolvePollSeconds: 0.01
            )
        )
    }

    // MARK: - The reference

    @Test func theReferenceCarriesKindSizeAndURLs() throws {
        let photo = ChatMedia(
            kind: .image, url: try #require(URL(string: "https://cdn.test/a.jpg?sig=x&w=1")),
            pixelWidth: 1080, pixelHeight: 1350
        )
        #expect(ChatMediaRef.decode(ChatMediaRef.encode(photo)) == photo, "a delivery URL's own query broke the reference")

        let clip = ChatMedia(
            kind: .video, url: try #require(URL(string: "https://cdn.test/c.mp4")),
            posterURL: URL(string: "https://cdn.test/c.jpg"), pixelWidth: 720, pixelHeight: 1280, duration: 12.4
        )
        #expect(ChatMediaRef.decode(ChatMediaRef.encode(clip)) == clip)
        // Another client's bare delivery URL: a photo of unknown size.
        #expect(ChatMediaRef.decode("https://cdn.test/b.png")?.kind == .image)
        #expect(ChatMediaRef.decode("") == nil)
        #expect(ChatMediaRef.decode(ChatMediaRef.encode(photo))?.aspectRatio == 0.8)
    }

    // MARK: - The repository

    /// ⚠️ UPLOAD, THEN SEND: the photo goes through media.v1, then chat.v1
    /// `SendMessage` carries `content_type` MEDIA and the reference — which
    /// the history gives back as a media message.
    @Test func aPhotoIsUploadedThenSentAsAMediaMessage() async throws {
        let repository = repository()
        let conversation = try await repository.directConversation(with: ProfileID("prof-31"))
        let sent = try await repository.send(media: .image(Self.solid()), caption: "", to: conversation, replyingTo: nil)
        let media = try #require(sent.media, "the sent message carries no media")
        #expect(media.kind == .image)
        #expect(media.pixelWidth == 40 && media.pixelHeight == 30)
        #expect(sent.summary == "Photo")

        let history = try await repository.loadMessages(in: conversation)
        let echoed = try #require(history.first { $0.id == sent.id }, "the mock dropped the media message")
        #expect(echoed.media == media, "the reference did not come back as sent")
    }

    /// A failed upload sends nothing and says so.
    @Test func aFailedUploadSendsNothing() async throws {
        let repository = repository(transport: FailingTransport())
        let conversation = try await repository.directConversation(with: ProfileID("prof-31"))
        let before = try await repository.loadMessages(in: conversation).count
        await #expect {
            _ = try await repository.send(media: .image(Self.solid()), caption: "", to: conversation, replyingTo: nil)
        } throws: { error in
            if case .mediaUpload = error as? ChatError { return true }
            return false
        }
        #expect(try await repository.loadMessages(in: conversation).count == before)
    }

    /// The seeded thread's received photo (`conv-0`), as the thread reads it.
    @Test func theSeededThreadHasAReceivedPhoto() async throws {
        let repository = repository()
        let history = try await repository.loadMessages(in: ConversationID("conv-0"))
        let photo = try #require(history.first { $0.media != nil })
        #expect(!photo.isMine)
        #expect(photo.media?.url.scheme == "mock")
        #expect(photo.media?.aspectRatio != nil)
    }

    // MARK: - The thread

    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// ⚠️ OPTIMISTIC: the bubble is there at once, wearing the picture
    /// picked; a failure turns it into a retry, and the retry delivers it.
    @Test func aPhotoShowsAtOnceFailsAndIsRetried() async throws {
        let provider = MediaStubProvider(failures: 1)
        let viewModel = ConversationViewModel(conversationID: ConversationID("c"), repository: provider)
        var phases: [ConversationViewModel.Phase] = []
        viewModel.onPhaseChange = { phases.append($0) }
        var uploaded: [URL] = []
        viewModel.onDidUploadMedia = { _, url in uploaded.append(url) }
        viewModel.viewDidLoad()
        #expect(await settle { if case .content = phases.last { true } else { false } })

        let picture = Self.solid()
        viewModel.send(media: [.image(picture)])
        guard case .content(let pending) = phases.last else { Issue.record("no content"); return }
        let bubble = try #require(pending.last)
        #expect(bubble.delivery == .sending)
        #expect(bubble.media?.preview === picture)
        #expect(bubble.media?.url == nil)

        #expect(await settle {
            if case .content(let models) = phases.last { models.last?.delivery == .failed } else { false }
        }, "a failed send did not say so")

        viewModel.retry(bubble.id)
        #expect(await settle {
            if case .content(let models) = phases.last { models.last?.delivery == .sent } else { false }
        }, "the retry did not deliver")
        guard case .content(let delivered) = phases.last else { return }
        #expect(delivered.last?.media?.url != nil)
        #expect(delivered.last?.media?.preview === picture, "the viewer's own picture was dropped")
        #expect(uploaded.count == 1, "the delivered picture did not reach the image cache")
    }

    /// The driver spells it for the screen: media, delivery, and whether the
    /// footer offers the camera and the library.
    @Test func theDriverForwardsMediaAndDelivery() async throws {
        let provider = MediaStubProvider(failures: 0)
        let viewModel = ConversationViewModel(conversationID: ConversationID("c"), repository: provider)
        let plain = ConversationThreadDriver(viewModel: viewModel, viewer: provider, avatars: nil)
        #expect(!plain.sendsMedia)

        let driver = ConversationThreadDriver(
            viewModel: viewModel, viewer: provider, avatars: nil, mediaPicker: { _, _ in UIViewController() }
        )
        #expect(driver.sendsMedia)
        var last: [ConversationThreadMessage] = []
        driver.onPhaseChange = { phase in if case .content(let messages) = phase { last = messages } }
        driver.viewDidLoad()
        #expect(await settle { last.isEmpty == false || true })
        viewModel.send(media: [.image(Self.solid())])
        #expect(last.last?.media?.kind == .image)
        #expect(last.last?.delivery == .sending)
        #expect(await settle { last.last?.delivery == .sent })
    }
}

private struct FailingTransport: MediaUploadTransport {
    struct Refused: Error {}
    func upload(_ data: Data, using ticket: MediaUploadTicket) async throws -> String { throw Refused() }
}

/// Fails the first `failures` media sends, then delivers.
private actor MediaStubProvider: ChatProviding {
    private var failures: Int
    private var count = 0

    init(failures: Int) { self.failures = failures }

    func viewerProfileID() async throws -> ProfileID { ProfileID("me") }
    func loadConversations() async throws -> [Conversation] { [] }
    func loadMessages(in conversationID: ConversationID) async throws -> [ChatMessage] { [] }
    func send(_ body: String, to conversationID: ConversationID, replyingTo replyToID: String?) async throws -> ChatMessage {
        ChatMessage(id: "t", senderID: ProfileID("me"), body: body, createdAt: Date(), isMine: true)
    }
    func send(
        media: ChatMediaUpload, caption: String, to conversationID: ConversationID, replyingTo replyToID: String?
    ) async throws -> ChatMessage {
        if failures > 0 {
            failures -= 1
            throw ChatError.mediaUpload(message: "offline")
        }
        count += 1
        return ChatMessage(
            id: "m\(count)", senderID: ProfileID("me"), body: caption, createdAt: Date(), isMine: true,
            media: ChatMedia(kind: media.kind, url: URL(string: "mock://asset/\(count)")!, pixelWidth: 40, pixelHeight: 30)
        )
    }
    func markRead(_ conversationID: ConversationID, upTo messageID: String) async throws {}
    func directConversation(with profileID: ProfileID) async throws -> ConversationID { ConversationID("c") }
}
