import AuthInterface
import CoreContracts
import CoreMedia
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
import UIKit
@testable import Upload

private struct ViewerSessionStub: AuthSessionProviding {
    func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
    func stateUpdates() async -> AsyncStream<AuthState> {
        AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
    }
    func logout() async {}
}

private func solidImage(_ size: CGSize = CGSize(width: 400, height: 300)) -> UIImage {
    UIGraphicsImageRenderer(size: size).image { ctx in
        UIColor.systemTeal.setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
    }
}

@MainActor
struct PostComposerTests {
    private struct Harness {
        let composer: PostComposer
        let bff: MockBFF
        let channel: ComposedPostChannel
        let postStore: MockPostStore
    }

    private func makeHarness() -> Harness {
        let bff = MockBFF()
        let blobStore = MockBlobStore()
        let postStore = MockPostStore()
        MockAuthService().register(on: bff)
        MockSocialServices(postStore: postStore).register(on: bff)
        MockMediaService(store: blobStore).register(on: bff)
        MockPostAuthoringService(store: postStore).register(on: bff)

        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let channel = ComposedPostChannel()
        let composer = PostComposer(
            mediaClient: Media_V1_MediaServiceClient(client: client),
            postClient: Post_V1_PostServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: ViewerSessionStub(),
            uploadTransport: MockMediaUploadTransport(store: blobStore),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            composedChannel: channel
        )
        return Harness(composer: composer, bff: bff, channel: channel, postStore: postStore)
    }

    @Test func imagePostRunsFullFlowAndBroadcastsEntry() async throws {
        let harness = makeHarness()
        let entries = await harness.channel.entries()

        try await harness.composer.publish(image: PickedImage(solidImage()), caption: "Hello world")

        var iterator = entries.makeAsyncIterator()
        let entry = await iterator.next()
        let unwrapped = try #require(entry)
        #expect(unwrapped.post.caption == "Hello world")
        #expect(unwrapped.author.id == ProfileID(MockSocialDataset.viewerProfileID))
        #expect(unwrapped.post.attachments.count == 1)
        #expect(unwrapped.post.attachments.first?.url != nil)

        // The whole media + post pipeline was exercised, in order.
        let paths = harness.bff.recordedRequests.map(\.path)
        #expect(paths.contains("/media.v1.MediaService/IssueUploadTicket"))
        #expect(paths.contains("/media.v1.MediaService/CommitUpload"))
        #expect(paths.contains("/media.v1.MediaService/ResolveDelivery"))
        #expect(paths.contains("/post.v1.PostService/CreatePost"))
        #expect(paths.contains("/post.v1.PostService/PublishPost"))
        // Ticket must precede commit must precede create.
        #expect(paths.firstIndex(of: "/media.v1.MediaService/IssueUploadTicket")! < paths.firstIndex(of: "/media.v1.MediaService/CommitUpload")!)
        #expect(paths.firstIndex(of: "/media.v1.MediaService/CommitUpload")! < paths.firstIndex(of: "/post.v1.PostService/CreatePost")!)
        #expect(paths.firstIndex(of: "/post.v1.PostService/CreatePost")! < paths.firstIndex(of: "/post.v1.PostService/PublishPost")!)
    }

    @Test func textOnlyPostSkipsMediaFlow() async throws {
        let harness = makeHarness()
        let entries = await harness.channel.entries()

        try await harness.composer.publish(image: nil, caption: "Just text")

        var iterator = entries.makeAsyncIterator()
        let entry = try #require(await iterator.next())
        #expect(entry.post.attachments.isEmpty)

        let paths = harness.bff.recordedRequests.map(\.path)
        #expect(!paths.contains("/media.v1.MediaService/IssueUploadTicket"))
        #expect(paths.contains("/post.v1.PostService/PublishPost"))
    }

    @Test func emptyPostThrowsWithoutHittingNetwork() async {
        let harness = makeHarness()

        await #expect(throws: ComposeError.emptyPost) {
            try await harness.composer.publish(image: nil, caption: "   ")
        }
        #expect(harness.bff.recordedRequests.isEmpty)
    }

    @Test func publishedPostAppearsAtTopOfRefreshedFeed() async throws {
        let harness = makeHarness()

        try await harness.composer.publish(image: PickedImage(solidImage()), caption: "Fresh post")

        // A subsequent timeline read must surface the authored post first.
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: harness.bff)
        var request = Timeline_V1_GetFollowingFeedRequest()
        request.profileID = MockSocialDataset.viewerProfileID
        request.limit = 5
        let response = await Timeline_V1_TimelineServiceClient(client: client).getFollowingFeed(request: request, headers: [:])
        let body = try response.result.get()
        #expect(body.items.first?.authorID == MockSocialDataset.viewerProfileID)
    }
}
