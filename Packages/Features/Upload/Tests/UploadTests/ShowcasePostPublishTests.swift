import AuthInterface
import Connect
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import FeedInterface
import Foundation
import MediaCore
import MediaPlayback
import Testing
@testable import Upload

/// Publishing a channel's showcase (#2216, part 3): a TEXT post whose create
/// request carries the channel's embed (`PostEmbedWire`) and, when the author
/// gave one, its place (`location`) — no attachment, no `audio_ref` — and the
/// mock serving both back.
@MainActor
struct ShowcasePostPublishTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    private struct Rig {
        let bff: MockBFF
        let client: any ProtocolClientInterface
        let composer: PostComposer
    }

    private func rig() -> Rig {
        let bff = MockBFF()
        let blobStore = MockBlobStore()
        let postStore = MockPostStore()
        MockAuthService().register(on: bff)
        MockSocialServices(postStore: postStore).register(on: bff)
        MockMediaService(store: blobStore).register(on: bff)
        MockPostAuthoringService(store: postStore).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let composer = PostComposer(
            mediaClient: Media_V1_MediaServiceClient(client: client),
            postClient: Post_V1_PostServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: Session(),
            uploadTransport: MockMediaUploadTransport(store: blobStore),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            composedChannel: ComposedPostChannel()
        )
        return Rig(bff: bff, client: client, composer: composer)
    }

    private let embed = PostEmbed.channel(ChannelEmbed(
        conversationID: ConversationID("ch-daily"), name: "Daily light", subscriberCount: 820, viewerState: .member
    ))
    private let bercy = TextPostPlace(name: "Skatepark de Bercy", latitude: 48.8349, longitude: 2.3814)

    private func served(_ id: PostID, on rig: Rig) async throws -> Post_V1_PostView {
        var get = Post_V1_GetPostRequest()
        get.postID = id.rawValue
        return try await Post_V1_PostServiceClient(client: rig.client).getPost(request: get, headers: [:]).result.get()
    }

    @Test func aShowcaseCarriesItsEmbedAndItsPlace() async throws {
        let rig = rig()
        let publisher = ComposerTextPostPublisher(composer: rig.composer)
        let entry = try await publisher.publishTextPost("The channel for tonight's light", embed: embed, place: bercy, as: nil)
        // A text post, the card on it at once.
        #expect(entry.post.attachments.isEmpty && entry.post.voice == nil)
        #expect(entry.post.embed == embed)
        #expect(entry.post.caption == "The channel for tonight's light")
        // No upload: a showcase has nothing to send but the request.
        let paths = rig.bff.recordedRequests.map(\.path)
        #expect(!paths.contains("/media.v1.MediaService/IssueUploadTicket"))
        #expect(paths.contains("/post.v1.PostService/CreatePost"))
        #expect(paths.contains("/post.v1.PostService/PublishPost"))
        // As served: the embed and the place, still a text post.
        let view = try await served(entry.post.id, on: rig)
        #expect(view.kind == .textOnly && view.attachments.isEmpty && !view.hasAudioRef)
        #expect(PostEmbedWire.embed(in: view)?.channel?.conversationID == ConversationID("ch-daily"))
        #expect(view.hasLocation)
        #expect(view.location.lat == bercy.latitude && view.location.lng == bercy.longitude)
    }

    @Test func withoutAPlaceTheRequestCarriesNone() async throws {
        let rig = rig()
        let entry = try await rig.composer.publishShowcasePost(
            caption: "Join", embed: embed, place: nil, as: nil, idempotencyKey: "showcase-key-0001"
        )
        let view = try await served(entry.post.id, on: rig)
        #expect(PostEmbedWire.embed(in: view) != nil)
        #expect(!view.hasLocation)
    }

    /// Several showcases may point to one channel; a new place is a new post.
    @Test func theKeyCoversTheChannelAndThePlace() {
        let plain = ComposerTextPostPublisher.showcaseContent("Join", embed: embed, place: nil, author: nil)
        let placed = ComposerTextPostPublisher.showcaseContent("Join", embed: embed, place: bercy, author: nil)
        let other = ComposerTextPostPublisher.showcaseContent(
            "Join", embed: .channel(ChannelEmbed(conversationID: ConversationID("ch-harbour"))), place: nil, author: nil
        )
        #expect(plain != placed)
        #expect(plain != other)
    }

    /// A publisher that sends no embed (fakes) refuses a showcase rather than
    /// posting its words alone.
    @Test func aPublisherWithoutEmbedsRefusesOne() async throws {
        struct TextOnly: TextPostPublishing {
            func publishTextPost(_ text: String, as author: AuthorSummary?) async throws -> FeedEntry {
                FeedEntry(
                    post: Post(id: PostID("p"), authorID: ProfileID("a"), caption: text, attachments: [], publishedAt: Date()),
                    author: AuthorSummary(id: ProfileID("a"), handle: "a", displayName: "A", avatarURL: nil)
                )
            }
        }
        let embed = embed
        await #expect(throws: TextPostEmbedUnsupported.self) {
            _ = try await TextOnly().publishTextPost("Join", embed: embed, place: nil, as: nil)
        }
    }
}
