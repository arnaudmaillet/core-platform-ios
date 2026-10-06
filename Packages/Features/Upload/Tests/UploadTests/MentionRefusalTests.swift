import AuthInterface
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

    private func makeComposer(postStore: MockPostStore) -> PostComposer {
        let bff = MockBFF()
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
            uploadTransport: MockMediaUploadTransport(store: blobStore),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            composedChannel: ComposedPostChannel()
        )
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
