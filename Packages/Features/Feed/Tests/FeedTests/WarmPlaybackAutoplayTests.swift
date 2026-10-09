import CoreModels
import CoreStorage
import Foundation
import MediaCore
import MediaPlayback
import Testing
@testable import Feed

/// The flight warm into a full-screen post (`warmPlayback`) does not ask
/// Autoplay (#702): the post it lands on plays whatever Autoplay says.
@MainActor
@Suite(.serialized)
struct WarmPlaybackAutoplayTests {
    private struct StubSource: VideoSource {
        func playableURL(for url: URL) async throws -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("stub.mp4")
        }
    }

    /// Hydrated with one clip, as the map's warmed posts are.
    private final class ClipProvider: FeedProviding, @unchecked Sendable {
        static let entry = FeedEntry(
            post: Post(
                id: PostID("clip-post"), authorID: ProfileID("a"), caption: "",
                attachments: [MediaAttachment(
                    url: URL(string: "mock://video/warm")!, thumbnailURL: nil,
                    mimeType: "video/mp4", pixelWidth: 720, pixelHeight: 1280
                )],
                publishedAt: Date(timeIntervalSince1970: 0)
            ),
            author: AuthorSummary(id: ProfileID("a"), handle: "ava", displayName: "Ava", avatarURL: nil),
            likeCount: 0
        )
        func cachedFirstPage() async -> [FeedEntry]? { nil }
        func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
        func loadPage(afterToken token: String) async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
        func loadPost(_ id: PostID) async throws -> FeedEntry { Self.entry }
        nonisolated func peekPost(_ id: PostID) -> FeedEntry? { id == Self.entry.post.id ? Self.entry : nil }
    }

    @Test func theFlightWarmRunsWithAutoplayNever() {
        let previousStore = MediaPlaybackPolicy.store
        defer { MediaPlaybackPolicy.store = previousStore }
        let store = MediaPlaybackPreferencesStore(defaults: UserDefaults(suiteName: "warm-\(UUID().uuidString)")!)
        store.update { $0.autoplay = .never }
        MediaPlaybackPolicy.store = store
        #expect(!MediaPlaybackPolicy.autoplays, "guard: grids would not autoplay")

        let builder = FeedFeatureBuilder(
            repository: ClipProvider(),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: VideoPlaybackController(source: StubSource(), poolSize: 2, capacity: 2)
        )
        let warm = builder.warmPlayback(of: PostID("clip-post"), at: nil)
        #expect(warm != nil, "the warm into a full-screen post refused on Autoplay Never")
        warm?.end(opened: false)
    }
}
