import AuthInterface
import Connect
import CoreContracts
import MediaCore
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
import UIKit
@testable import Upload

/// A post mentioning someone who doesn't allow mentions from its author
/// (#397, backend #656) is refused by the server, and the app says why.
@MainActor
struct MentionRefusalTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    private func makeComposer(
        postStore: MockPostStore, faults: MockNetworkFaults? = nil, bff: MockBFF = MockBFF()
    ) -> PostComposer {
        bff.faults = faults
        let blobStore = MockBlobStore()
        MockAuthService().register(on: bff)
        MockSocialServices(postStore: postStore).register(on: bff)
        MockMediaService(store: blobStore).register(on: bff)
        MockPostAuthoringService(store: postStore, mayMention: { _, handle in handle != "no.mentions" }).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return PostComposer(
            mediaClient: Media_V1_MediaServiceClient(client: client),
            postClient: Post_V1_PostServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: Session(),
            viewer: nil,
            uploadTransport: MockMediaUploadTransport(store: blobStore, faults: faults),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            composedChannel: ComposedPostChannel()
        )
    }

    /// A publish made offline fails remembering it was offline, and the
    /// author is told "You're offline"; a server fault keeps the screen's
    /// words (#794). The mock's own switchboard, never a shared one.
    @Test func anOfflinePublishSaysYoureOffline() async throws {
        let faults = MockNetworkFaults()
        faults.isForcedOffline = true
        let composer = makeComposer(postStore: MockPostStore(), faults: faults)

        let error = await #expect(throws: ComposeError.self) {
            try await composer.publish(media: .image(PickedImage(image())), caption: "hi")
        }

        #expect(error?.networkFailure == .offline)
        #expect(error.map(NewPostViewController.message(for:)) == FailureCopy.offline)
        #expect(
            NewPostViewController.message(for: .transport("boom", failure: .server(code: "internal"))) == "boom"
        )
    }

    /// ⚠️ A CreatePost whose connection dropped mid-request may have landed
    /// (#795): it is `unconfirmed`, and the author is told to check their
    /// profile, never to try again — though a lost link reads as offline
    /// (#794). Offline before the request left keeps "try again".
    @Test func aCreatePostCutOffMidRequestIsUnconfirmedNotARetry() async throws {
        let postStore = MockPostStore()
        let bff = MockBFF()
        let composer = makeComposer(postStore: postStore, bff: bff)
        bff.register(path: "/post.v1.PostService/CreatePost") { (_: Post_V1_CreatePostRequest) in
            Result<Post_V1_CreatePostResponse, ConnectError>.failure(ConnectError(
                code: .unavailable, message: "lost", exception: URLError(.networkConnectionLost)
            ))
        }

        let error = await #expect(throws: ComposeError.self) {
            try await composer.publish(media: nil, caption: "hi")
        }

        guard case .unconfirmed = error else {
            Issue.record("expected unconfirmed, got \(String(describing: error))")
            return
        }
        #expect(error?.networkFailure == .offline)
        let said = error.map(NewPostViewController.message(for:)) ?? ""
        #expect(said == ComposeError.unconfirmedMessage)
        #expect(!said.localizedCaseInsensitiveContains("try again"))
        #expect(error?.errorDescription == ComposeError.unconfirmedMessage, "the Text Post page says it too")

        // Offline BEFORE the request left: nothing was sent, so "try again".
        let before = ComposeError.transport("x", failure: .offline)
        #expect(NewPostViewController.message(for: before) == FailureCopy.offline)
    }

    private func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 200, height: 150)).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 150))
        }
    }

    @Test func aRefusedMentionIsSaidAndNothingIsPosted() async throws {
        let postStore = MockPostStore()
        let composer = makeComposer(postStore: postStore)
        await #expect(throws: ComposeError.mentionRefused) {
            try await composer.publish(media: .image(PickedImage(image())), caption: "Look @no.mentions, hi")
        }
        #expect(ComposeError.mentionRefused.errorDescription?.contains("doesn't allow mentions") == true)
        #expect(ComposeError.transport("x").errorDescription == nil)

        let posted = try await composer.publish(media: .image(PickedImage(image())), caption: "Thanks @ava.moreau!")
        #expect(posted.post.caption == "Thanks @ava.moreau!")
    }

    @Test func handlesAreReadFromTheCaption() {
        #expect(MockPostAuthoringService.mentionedHandles(in: "hi @ava.moreau, and @kenji_dev.") == ["ava.moreau", "kenji_dev"])
        #expect(MockPostAuthoringService.mentionedHandles(in: "no mentions here").isEmpty)
    }
}
