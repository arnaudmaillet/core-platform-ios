import AuthInterface
import CoreContracts
import MediaCore
import MediaPlayback
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
        let pipeline: ImagePipeline

        /// How many assets were uploaded. A video post issues TWO — the clip and
        /// its poster still — where an image post issues one.
        var ticketCount: Int {
            bff.recordedRequests.filter { $0.path == "/media.v1.MediaService/IssueUploadTicket" }.count
        }
    }

    /// `posterFrame` stands in for the one step whose FAILURE has to be
    /// exercised: a real exporter always finds a frame in a file it just wrote.
    private func makeHarness(
        posterFrame: (@Sendable (URL) async -> UIImage?)? = nil
    ) -> Harness {
        let bff = MockBFF()
        let blobStore = MockBlobStore()
        let postStore = MockPostStore()
        MockAuthService().register(on: bff)
        MockSocialServices(postStore: postStore).register(on: bff)
        MockMediaService(store: blobStore).register(on: bff)
        MockPostAuthoringService(store: postStore).register(on: bff)

        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let channel = ComposedPostChannel()
        let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())
        let composer = PostComposer(
            mediaClient: Media_V1_MediaServiceClient(client: client),
            postClient: Post_V1_PostServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: ViewerSessionStub(),
            uploadTransport: MockMediaUploadTransport(store: blobStore),
            imagePipeline: pipeline,
            composedChannel: channel,
            posterFrame: posterFrame ?? { await VideoExporter().posterImage(for: $0) }
        )
        return Harness(
            composer: composer, bff: bff, channel: channel, postStore: postStore, pipeline: pipeline
        )
    }

    @Test func imagePostRunsFullFlowAndBroadcastsEntry() async throws {
        let harness = makeHarness()
        let entries = await harness.channel.entries()

        try await harness.composer.publish(media: .image(PickedImage(solidImage())), caption: "Hello world")

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

    @Test func videoPostExportsUploadsAndBroadcastsLocalPlayableEntry() async throws {
        let harness = makeHarness()
        let entries = await harness.channel.entries()

        // A real source clip to pick.
        let source = try await PlaceholderVideoFetcher(durationSeconds: 1.0)
            .playableURL(for: URL(string: "mock://video/compose?w=240&h=320")!)

        try await harness.composer.publish(media: .video(PickedVideo(sourceURL: source)), caption: "my clip")

        var iterator = entries.makeAsyncIterator()
        let entry = try #require(await iterator.next())
        let attachment = try #require(entry.post.attachments.first)
        #expect(attachment.mimeType == "video/mp4")
        // Optimistic entry plays the exported LOCAL file, not a CDN URL.
        #expect(attachment.url?.isFileURL == true)
        #expect(attachment.pixelWidth > 0 && attachment.pixelHeight > 0)

        // Same media + post pipeline as images, in order.
        let paths = harness.bff.recordedRequests.map(\.path)
        #expect(paths.contains("/media.v1.MediaService/IssueUploadTicket"))
        #expect(paths.contains("/media.v1.MediaService/CommitUpload"))
        #expect(paths.contains("/post.v1.PostService/CreatePost"))
        #expect(paths.contains("/post.v1.PostService/PublishPost"))
    }

    /// ⚠️ **THE DEFECT THIS EXISTS TO CATCH IS INVISIBLE IN MOCK MODE AND LOOKS
    /// LIKE NOTHING AT ALL.** `thumbnail_url` used to be the .mp4's own URL. That
    /// is not "no picture": every surface resolves a thumbnail through
    /// `ImagePipeline`, whose FETCH of a video succeeds and whose decode then
    /// fails — so the placeholder rescue never fires, nothing negative-caches,
    /// and each re-bind re-downloads the clip through the image path. A black
    /// snap-feed area, dark grid tiles, a blank hero flight, and autoplay
    /// withheld forever because `hasCover` never becomes true.
    ///
    /// `MockSocialServices` never points a thumbnail at a video, so no simulator
    /// run reproduces it. This does.
    @Test func aVideosThumbnailIsAPosterStillAndNotTheClip() async throws {
        let harness = makeHarness()
        let entries = await harness.channel.entries()
        let source = try await PlaceholderVideoFetcher(durationSeconds: 1.0)
            .playableURL(for: URL(string: "mock://video/poster?w=240&h=320")!)

        try await harness.composer.publish(media: .video(PickedVideo(sourceURL: source)), caption: "clip")

        var iterator = entries.makeAsyncIterator()
        let entry = try #require(await iterator.next())
        let attachment = try #require(entry.post.attachments.first)
        let thumbnail = try #require(attachment.thumbnailURL)

        #expect(thumbnail != attachment.url, "the thumbnail must not be the clip itself")
        #expect(thumbnail.isFileURL == false, "the poster is uploaded, so it wears a delivery URL")
        // TWO assets: the clip, then the poster. An image post issues one — the
        // witness below — so this count can fail.
        #expect(harness.ticketCount == 2, "expected a clip + a poster, got \(harness.ticketCount)")
        // Seeded under the exact URL the feed will ask for, already decoded.
        #expect(await harness.pipeline.cachedImage(for: thumbnail) != nil,
                "the author's own post must draw its poster without a round trip")
    }

    /// The witness for the count above: without it, `== 2` could be measuring
    /// two tickets that every post issues rather than the poster's own.
    @Test func anImagePostIssuesOneTicket() async throws {
        let harness = makeHarness()
        try await harness.composer.publish(media: .image(PickedImage(solidImage())), caption: "one")
        #expect(harness.ticketCount == 1)
    }

    /// ⚠️ **A DECORATION MUST NEVER LOSE THE AUTHOR'S VIDEO.** The poster is
    /// best-effort, and this is the branch a real exporter can never reach —
    /// which is exactly why it is injected.
    @Test func aVideoStillPublishesWhenItsPosterCannotBeMade() async throws {
        let harness = makeHarness(posterFrame: { _ in nil })
        let entries = await harness.channel.entries()
        let source = try await PlaceholderVideoFetcher(durationSeconds: 1.0)
            .playableURL(for: URL(string: "mock://video/noposter?w=240&h=320")!)

        try await harness.composer.publish(media: .video(PickedVideo(sourceURL: source)), caption: "clip")

        var iterator = entries.makeAsyncIterator()
        let entry = try #require(await iterator.next())
        let attachment = try #require(entry.post.attachments.first)
        #expect(attachment.mimeType == "video/mp4")
        #expect(attachment.url?.isFileURL == true, "the clip still publishes and still plays locally")
        #expect(harness.ticketCount == 1, "no poster asset was uploaded")
        let paths = harness.bff.recordedRequests.map(\.path)
        #expect(paths.contains("/post.v1.PostService/PublishPost"))
    }

    @Test func textOnlyPostSkipsMediaFlow() async throws {
        let harness = makeHarness()
        let entries = await harness.channel.entries()

        try await harness.composer.publish(media: nil, caption: "Just text")

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
            try await harness.composer.publish(media: nil, caption: "   ")
        }
        #expect(harness.bff.recordedRequests.isEmpty)
    }

    @Test func publishedPostAppearsAtTopOfRefreshedFeed() async throws {
        let harness = makeHarness()

        try await harness.composer.publish(media: .image(PickedImage(solidImage())), caption: "Fresh post")

        // A subsequent timeline read must surface the authored post first.
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: harness.bff)
        var request = Timeline_V1_GetFollowingFeedRequest()
        request.profileID = MockSocialDataset.viewerProfileID
        request.limit = 5
        let response = await Timeline_V1_TimelineServiceClient(client: client).getFollowingFeed(request: request, headers: [:])
        let body = try response.result.get()
        #expect(body.items.first?.authorID == MockSocialDataset.viewerProfileID)
    }

    /// The entry comes back to the caller as well as down the channel, so a
    /// screen can become the post it just made without fetching it back.
    @Test func publishReturnsTheEntryItBroadcasts() async throws {
        let harness = makeHarness()
        let entries = await harness.channel.entries()

        let returned = try await harness.composer.publish(media: nil, caption: "Returned")

        var iterator = entries.makeAsyncIterator()
        let broadcast = try #require(await iterator.next())
        #expect(returned == broadcast)
        #expect(returned.post.caption == "Returned")
    }

    /// A post is BY the author the screen named — verbatim, face and all.
    @Test func publishingAsOneOfTheAccountsProfilesAuthorsThePost() async throws {
        let harness = makeHarness()
        let author = AuthorSummary(
            id: ProfileID(MockSocialDataset.viewerProfileID), handle: "you",
            displayName: "Demo Viewer", avatarURL: URL(string: "mock://avatar/viewer?w=128&h=128")
        )

        let entry = try await harness.composer.publish(media: nil, caption: "Mine", as: author)

        #expect(entry.author == author)
        #expect(entry.post.authorID == author.id)
    }

    /// …and never by a profile the account does not hold: that is refused
    /// before anything is created.
    @Test func publishingAsAProfileOutsideTheAccountIsRefused() async {
        let harness = makeHarness()
        let stranger = AuthorSummary(
            id: ProfileID("prof-not-mine"), handle: "stranger", displayName: "Stranger", avatarURL: nil
        )

        await #expect(throws: ComposeError.noViewerProfile) {
            try await harness.composer.publish(media: nil, caption: "Not mine", as: stranger)
        }
        #expect(!harness.bff.recordedRequests.map(\.path).contains("/post.v1.PostService/CreatePost"))
    }
}
