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

/// Publishing a voice post (#2209): the take uploaded as audio, then a TEXT
/// post created with it — no attachment, no `audio_ref` — and the author's
/// own voice playing at once from the take.
@MainActor
struct VoicePostPublishTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    private func take() throws -> TextPostVoice {
        let url = FileManager.default.temporaryDirectory.appending(path: "take-\(UUID().uuidString).m4a")
        try Data(repeating: 7, count: 4_096).write(to: url)
        return TextPostVoice(fileURL: url, duration: 12.64, waveform: (0..<100).map { UInt8($0 % 32) })
    }

    @Test func aVoicePostIsATextPostCarryingItsVoice() async throws {
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
        let voice = try take()
        let entry = try await composer.publishVoicePost(caption: "", voice: voice, as: nil, idempotencyKey: "voice-post-key-1")
        // A voice alone is a post; it stays text.
        #expect(entry.post.attachments.isEmpty)
        #expect(entry.post.caption.isEmpty)
        let local = try #require(entry.post.voice)
        #expect(local.url == voice.fileURL, "the author's own voice doesn't play from the take")
        #expect(local.duration == 12.6)
        #expect(local.waveform == voice.waveform)
        // The audio went up as an asset, then CreatePost carried the voice.
        let paths = bff.recordedRequests.map(\.path)
        #expect(paths.contains("/media.v1.MediaService/IssueUploadTicket"))
        #expect(paths.contains("/post.v1.PostService/CreatePost"))
        // As served: the post reads back with its voice and no attachment.
        var get = Post_V1_GetPostRequest()
        get.postID = entry.post.id.rawValue
        let view = try await Post_V1_PostServiceClient(client: client).getPost(request: get, headers: [:]).result.get()
        #expect(view.kind == .textOnly)
        #expect(view.attachments.isEmpty && !view.hasAudioRef)
        let served = try #require(PostVoiceWire.voice(in: view))
        #expect(served.duration == 12.6 && !served.assetID.isEmpty)
    }

    /// A publisher that doesn't send voices (fakes) refuses one rather than
    /// posting the words alone.
    @Test func aPublisherWithoutVoiceRefusesOne() async throws {
        struct TextOnly: TextPostPublishing {
            func publishTextPost(_ text: String, as author: AuthorSummary?) async throws -> FeedEntry {
                FeedEntry(
                    post: Post(id: PostID("p"), authorID: ProfileID("a"), caption: text, attachments: [], publishedAt: Date()),
                    author: AuthorSummary(id: ProfileID("a"), handle: "a", displayName: "A", avatarURL: nil)
                )
            }
        }
        let voice = try take()
        await #expect(throws: TextPostVoiceUnsupported.self) {
            _ = try await TextOnly().publishTextPost("", voice: voice, as: nil)
        }
        #expect(try await TextOnly().publishTextPost("Words", voice: nil, as: nil).post.caption == "Words")
    }

    @Test func aVoicePostLastsAMinuteAtMost() {
        #expect(TextPostVoice.maximumDuration == 60)
    }
}
