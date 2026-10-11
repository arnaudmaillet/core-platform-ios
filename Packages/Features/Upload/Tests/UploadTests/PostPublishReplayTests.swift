import AuthInterface
import Connect
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import MediaCore
import MediaPlayback
import Testing
@testable import Upload

/// ⚠️ **A LOST ANSWER IS NOT A LOST WRITE (#795).** post.v1 can create a
/// post and the answer never arrive: the author sees a failure, taps Post
/// again, and without a key the profile carries the post twice. These lose
/// the answer on purpose, against the mock BFF — and answer ABORTED, which is
/// what a repeat gets while the first CreatePost is still in flight.
struct PostPublishReplayTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    /// Hands every call to the mock BFF. While `losses` lasts, a call on
    /// `lossPath` is applied and its answer swapped for a transport failure.
    /// While `aborts` lasts, a CreatePost is NOT applied and is answered
    /// ABORTED, as post.v1 answers a repeat while the first call is still in
    /// flight (PST-1010).
    private final class FaultyRelay: HTTPClientInterface, @unchecked Sendable {
        private let bff: MockBFF
        private let lossPath: String
        private let lock = NSLock()
        private var losses: Int
        private var aborts: Int
        private let abortMessage: String
        private var creates = 0

        init(_ bff: MockBFF, losing losses: Int, on lossPath: String, aborting aborts: Int, abortMessage: String) {
            self.bff = bff
            self.lossPath = lossPath
            self.losses = losses
            self.aborts = aborts
            self.abortMessage = abortMessage
        }

        /// Every CreatePost that reached the relay, whatever its answer.
        var createCount: Int { lock.withLock { creates } }

        private enum Fault { case none, lose, abort }

        @discardableResult
        func unary(
            request: HTTPRequest<Data?>,
            onMetrics: @escaping @Sendable (HTTPMetrics) -> Void,
            onResponse: @escaping @Sendable (HTTPResponse) -> Void
        ) -> Cancelable {
            let path = request.url.path
            let fault: Fault = lock.withLock {
                if path.hasSuffix("/CreatePost") {
                    creates += 1
                    if aborts > 0 {
                        aborts -= 1
                        return .abort
                    }
                }
                if path.hasSuffix(lossPath), losses > 0 {
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
        let composer: PostComposer
        let relay: FaultyRelay
        let posts: MockPostStore
    }

    /// What post.v1 says when a CreatePost with the key is in flight: its
    /// error's text, the code kept in the service's logs.
    static let inFlight = "a CreatePost with this idempotency key is in flight"

    private func rig(
        losing losses: Int = 0, on lossPath: String = "/CreatePost", aborting aborts: Int = 0, waits: Int = 2,
        abortMessage: String = inFlight
    ) -> Rig {
        let bff = MockBFF()
        let blobs = MockBlobStore()
        let posts = MockPostStore()
        MockAuthService().register(on: bff)
        MockSocialServices(postStore: posts).register(on: bff)
        MockMediaService(store: blobs).register(on: bff)
        MockPostAuthoringService(store: posts).register(on: bff)
        let relay = FaultyRelay(bff, losing: losses, on: lossPath, aborting: aborts, abortMessage: abortMessage)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: relay)
        let composer = PostComposer(
            mediaClient: Media_V1_MediaServiceClient(client: client),
            postClient: Post_V1_PostServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: Session(),
            uploadTransport: MockMediaUploadTransport(store: blobs),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            composedChannel: ComposedPostChannel(),
            // No wall clock: the waits are there, and take no time.
            inFlightRetryDelays: Array(repeating: .zero, count: waits)
        )
        return Rig(composer: composer, relay: relay, posts: posts)
    }

    private func publish(_ rig: Rig, _ caption: String, key: String) async throws -> FeedEntry {
        try await rig.composer.publish(media: [], caption: caption, as: nil, idempotencyKey: key)
    }

    // MARK: - The composer

    /// The retry goes under the same key, and the mock answers it with the
    /// post it already created: one post, not two, and the same id.
    @Test func aRetriedPublishAfterALostCreateAnswerCreatesOnePost() async throws {
        let rig = rig(losing: 1, on: "/CreatePost")
        let key = IdempotencyKey.mint()

        await #expect(throws: ComposeError.self) { _ = try await publish(rig, "Lost answer", key: key) }
        #expect(rig.posts.createdCount == 1, "guard: the first CreatePost landed")
        let entry = try await publish(rig, "Lost answer", key: key)

        #expect(rig.posts.createdCount == 1, "the retry created a second post")
        #expect(entry.post.caption == "Lost answer")
    }

    /// The PublishPost answer lost instead: the retry's CreatePost is
    /// answered with the same draft — already published — and post.v1's
    /// "already published" (PST-1002) is the success it means: one post,
    /// published once.
    @Test func aRetriedPublishAfterALostPublishAnswerIsTheSamePost() async throws {
        let rig = rig(losing: 1, on: "/PublishPost")
        let key = IdempotencyKey.mint()

        await #expect(throws: ComposeError.self) { _ = try await publish(rig, "Published twice?", key: key) }
        try #require(rig.posts.publishedCount == 1, "guard: the lost PublishPost landed")
        let entry = try await publish(rig, "Published twice?", key: key)

        #expect(entry.post.caption == "Published twice?")
        #expect(rig.posts.createdCount == 1)
        #expect(rig.posts.publishedCount == 1)
    }

    /// The other half: another key is another post. Without this, a mock
    /// that answered every CreatePost with the first post would pass above.
    @Test func anotherKeyIsAnotherPost() async throws {
        let rig = rig()

        let first = try await publish(rig, "Same words", key: IdempotencyKey.mint())
        let second = try await publish(rig, "Same words", key: IdempotencyKey.mint())

        #expect(first.post.id != second.post.id)
        #expect(rig.posts.createdCount == 2)
    }

    /// ⚠️ ABORTED IS "NOT YET": the first CreatePost is still in flight on
    /// the server, so the repeat waits and asks again under the same key —
    /// and the publish never fails for it.
    @Test func aCreateAbortedWhileItsFirstIsInFlightIsAskedAgain() async throws {
        let rig = rig(aborting: 2, waits: 2)

        let entry = try await publish(rig, "In flight", key: IdempotencyKey.mint())

        #expect(rig.relay.createCount == 3)
        #expect(rig.posts.createdCount == 1)
        #expect(entry.post.caption == "In flight")
    }

    /// Past the last wait, ABORTED fails like any other failure — and the
    /// author's retry, under the same key, makes the post once.
    @Test func aCreateStillAbortedAfterTheLastWaitFailsAndItsRetryLands() async throws {
        let rig = rig(aborting: 2, waits: 1)
        let key = IdempotencyKey.mint()

        await #expect(throws: ComposeError.self) { _ = try await publish(rig, "Later", key: key) }
        #expect(rig.relay.createCount == 2, "the repeat did not wait and ask again")
        _ = try await publish(rig, "Later", key: key)

        #expect(rig.posts.createdCount == 1)
    }

    /// Only the in-flight ABORTED is waited out: any other is a failure.
    @Test func anotherAbortedIsNotAskedAgain() async throws {
        let rig = rig(aborting: 1, waits: 2, abortMessage: "transaction aborted")

        await #expect(throws: ComposeError.self) { _ = try await publish(rig, "Other", key: IdempotencyKey.mint()) }
        #expect(rig.relay.createCount == 1)
    }

    /// Without a key there is nothing to wait for: ABORTED is a failure.
    @Test func aKeylessPublishIsNotAskedAgain() async throws {
        let rig = rig(aborting: 1, waits: 2)

        await #expect(throws: ComposeError.self) {
            _ = try await rig.composer.publish(media: [], caption: "No key", as: nil)
        }
        #expect(rig.relay.createCount == 1)
    }

    // MARK: - The Text Post screen's publisher

    /// Records the key of every publish; fails the first `failures`.
    private actor KeyRecordingComposer: PostComposing {
        private(set) var keys: [String] = []
        private var failures: Int

        init(failures: Int) { self.failures = failures }

        func publish(media: [ComposeMedia], caption: String, as author: AuthorSummary?) async throws -> FeedEntry {
            try await publish(media: media, caption: caption, as: author, idempotencyKey: "")
        }

        func publish(
            media: [ComposeMedia], caption: String, as author: AuthorSummary?, idempotencyKey: String
        ) async throws -> FeedEntry {
            keys.append(idempotencyKey)
            if failures > 0 {
                failures -= 1
                throw ComposeError.transport("the answer was lost")
            }
            let by = author ?? AuthorSummary(id: ProfileID("first"), handle: "first", displayName: "First", avatarURL: nil)
            return FeedEntry(
                post: Post(id: PostID("p\(keys.count)"), authorID: by.id, caption: caption, attachments: [], publishedAt: .distantPast),
                author: by, likeCount: 0
            )
        }
    }

    /// One key per publish intent: the retry of the same text reuses it, an
    /// edited text takes a new one, and once a post is up the same text again
    /// is a new post with a new key.
    @Test func theTextPostPublisherKeysEachIntentOnce() async throws {
        let composer = KeyRecordingComposer(failures: 2)
        let publisher = ComposerTextPostPublisher(composer: composer)

        await #expect(throws: ComposeError.self) { _ = try await publisher.publishTextPost("Hello", as: nil) }
        await #expect(throws: ComposeError.self) { _ = try await publisher.publishTextPost("Hello ", as: nil) }
        _ = try await publisher.publishTextPost("Hello, world", as: nil)
        _ = try await publisher.publishTextPost("Hello, world", as: nil)

        let keys = await composer.keys
        try #require(keys.count == 4)
        #expect(keys.allSatisfy(IdempotencyKey.isValid))
        #expect(keys[1] == keys[0], "the retry of the same text went under a new key")
        #expect(keys[2] != keys[1], "an edited text reused the old key")
        #expect(keys[3] != keys[2], "a deliberate second post reused the first one's key")
    }
}
