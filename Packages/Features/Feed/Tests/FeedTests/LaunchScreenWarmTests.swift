import CoreModels
import Foundation
import MediaCore
import MediaPlayback
import Testing
@testable import Feed

/// Shots' first post warms while the shell builds (#1765): from the device's
/// first page, its picture decoded and — for a clip — its player prepared
/// with no surface yet, keyed as the page plays it, so the page's first
/// `play` adopts it.
@MainActor
struct LaunchScreenWarmTests {
    private static let clip = URL(string: "https://example.test/first.mp4")!
    private static let poster = URL(string: "https://example.test/first.jpg")!

    private func entry() -> FeedEntry {
        FeedEntry(
            post: Post(
                id: PostID("first"), authorID: ProfileID("a"), caption: "",
                attachments: [MediaAttachment(
                    url: Self.clip, thumbnailURL: Self.poster, mimeType: "video/mp4",
                    pixelWidth: 1080, pixelHeight: 1920
                )],
                publishedAt: Date(timeIntervalSince1970: 0)
            ),
            author: AuthorSummary(id: ProfileID("a"), handle: "ava", displayName: "Ava", avatarURL: nil)
        )
    }

    @Test func theFirstClipsPlayerAndPosterAreWarmed() async {
        let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())
        let pool = VideoPlaybackController(source: StubVideoSource(), poolSize: 3)
        let builder = FeedFeatureBuilder(
            repository: CachedFirstPage(entries: []),
            imagePipeline: pipeline,
            videoPlayback: pool,
            discovery: CachedFirstPage(entries: [entry()])
        )
        builder.warmLaunchScreen()
        for _ in 0..<300 where !(pool.hasLookaheadPlayback(of: Self.clip, scope: "first")
                                 && pipeline.cachedImage(for: Self.poster, size: .full) != nil) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(pool.hasLookaheadPlayback(of: Self.clip, scope: "first"), "the first clip's player was not prepared")
        #expect(pipeline.cachedImage(for: Self.poster, size: .full) != nil, "the first poster was not decoded")
    }
}

private struct StubVideoSource: VideoSource {
    func playableURL(for mediaURL: URL) async throws -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("stub.mp4")
    }
}

/// A device copy of a first page, and nothing from the network.
private final class CachedFirstPage: FeedProviding, @unchecked Sendable {
    let entries: [FeedEntry]
    init(entries: [FeedEntry]) { self.entries = entries }
    func cachedFirstPage() async -> [FeedEntry]? { entries.isEmpty ? nil : entries }
    func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPage(afterToken token: String) async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPost(_ id: PostID) async throws -> FeedEntry { throw FeedError.transport(message: "none") }
}
