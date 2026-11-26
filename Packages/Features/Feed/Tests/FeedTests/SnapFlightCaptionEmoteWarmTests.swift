import CoreModels
import CoreStorage
import EmoteKit
import MediaCore
import MediaCoreFixtures
import MediaUI
import Testing
import UIKit
@testable import Feed
@testable import PostSurfaces

/// Every hero that opens a post page warms the caption's emotes at take-off
/// (#2580), from the one seam all of them reach — the destination's
/// `zoomTransitionWillBegin` — at the bucket the flight's caption draws at, so
/// the replica shows the art from the flight's first frame.
///
/// The warm itself is recorded, not sent: the shared engine would bake.
/// `EmotePrefetchTests` holds what an urgent warm does.
@MainActor
struct SnapFlightCaptionEmoteWarmTests {
    private static let screen = CGRect(x: 0, y: 0, width: 390, height: 844)

    private static func post(caption: String?) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID("p1"), authorID: ProfileID("a"), authorName: "Ava", metaText: "",
            avatarURL: nil, caption: caption,
            mediaURL: URL(string: "mock://media/1"), mediaKind: .image,
            thumbnailURL: nil, audioText: nil, likeCount: 12
        )
    }

    private func makeFeed() -> SnapFeedViewController {
        let feed = SnapFeedViewController(
            viewModel: FeedViewModel(
                repository: FlightWarmSilentProvider(),
                unavailablePosts: UnavailablePosts(viewerEvents: ViewerEvents())
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            bookmarks: PostBookmarkStore(scope: StorageScope()),
            savedSounds: SavedSoundStore(scope: StorageScope()),
            viewer: { nil }
        )
        feed.loadViewIfNeeded()
        feed.view.frame = Self.screen
        return feed
    }

    /// A seeded opening (the map's held post, a grid's projection): its
    /// caption is asked for at take-off, at the side the flight's replica
    /// then draws its emotes at.
    @Test func aFlightWarmsTheCaptionsEmotesAtTakeOff() throws {
        let caption = "I can't believe it 🔥"
        let feed = makeFeed()
        feed.seedProjection([Self.post(caption: caption)])
        var warmed: [(captions: [String], side: Int)] = []
        feed.zoomDestination.warmFlightEmotes = { warmed.append(($0, $1)) }

        feed.zoomTransitionWillBegin(flyingLivePlayer: false)
        try #require(warmed.count == 1, "the take-off asked for nothing")
        #expect(warmed[0].captions == [caption])

        // The bucket the replica's caption really draws at, measured on its
        // placed emotes.
        let window = UIWindow(frame: Self.screen)
        window.isHidden = false
        defer { window.isHidden = true }
        let replica = try #require(feed.zoomFlightChrome() as? SnapChromeView)
        replica.frame = Self.screen
        window.addSubview(replica)
        replica.layoutIfNeeded()
        replica.captionLabel.layoutIfNeeded()
        let placed = replica.captionLabel.subviews.contains { $0 is AnimatedIconView }
        try #require(placed, "precondition: the replica placed its emotes")
        #expect(
            warmed[0].side == replica.captionEmotePixelSide,
            "warmed at \(warmed[0].side), drawn at \(replica.captionEmotePixelSide)"
        )
    }

    /// A cold open has no post at take-off, and a post with no caption has
    /// nothing to warm: nothing is asked for.
    @Test func aFlightWithNoCaptionWarmsNothing() {
        let cold = makeFeed()
        var warmed = 0
        cold.zoomDestination.warmFlightEmotes = { _, _ in warmed += 1 }
        cold.zoomTransitionWillBegin(flyingLivePlayer: false)
        #expect(warmed == 0, "a cold open asked for a caption it does not have")

        let bare = makeFeed()
        bare.seedProjection([Self.post(caption: nil)])
        bare.zoomDestination.warmFlightEmotes = { _, _ in warmed += 1 }
        bare.zoomTransitionWillBegin(flyingLivePlayer: false)
        #expect(warmed == 0, "a post with no caption asked for one")
    }
}

/// A repository that vends nothing: these tests seed what they need.
private final class FlightWarmSilentProvider: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry { throw CancellationError() }
}
