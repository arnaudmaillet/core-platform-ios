import CoreModels
import CoreNavigation
@testable import Feed
import MediaCore
import Testing
import UIKit

/// The full-screen post as the source of a profile window (#1874,
/// `-profile-window`): when it opens one, and that it never measures a
/// window onto nothing.
@MainActor
struct ProfileWindowSourceTests {
    private func makeFeed() -> SnapFeedViewController {
        let feed = SnapFeedViewController(
            viewModel: FeedViewModel(repository: WindowSilentProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        feed.loadViewIfNeeded()
        return feed
    }

    /// Flag off (the default): no window, from any feed.
    @Test func flagOffOpensNoWindow() {
        let feed = makeFeed()
        #expect(!feed.opensProfileWindows)
        #expect(feed.profileWindowGeometry(for: ProfileID("a"), launch: nil) == nil)
    }

    /// The Shots root keeps its push, flag or not.
    @Test func theShotsRootOpensNoWindow() {
        let feed = makeFeed()
        feed.profileWindowFlag = true
        feed.isForYouRoot = true
        #expect(!feed.opensProfileWindows)
        feed.isForYouRoot = false
        #expect(feed.opensProfileWindows == !HeroMotionPolicy.prefersNativePush)
    }

    /// No pill on screen and none kept: nil, the plain push or slide.
    @Test func noPillMeansNoWindow() {
        let feed = makeFeed()
        feed.profileWindowFlag = true
        #expect(feed.profileWindowGeometry(for: ProfileID("a"), launch: nil) == nil)
    }

    /// A pill kept from the opening lands the close only while the pill still
    /// shows that author.
    @Test func aKeptPillForAnotherAuthorIsNoLanding() {
        let feed = makeFeed()
        feed.profileWindowFlag = true
        feed.profileWindowPill = (ProfileID("a"), CGRect(x: 16, y: 800, width: 160, height: 48), UIImage())
        #expect(feed.profileWindowGeometry(for: ProfileID("b"), launch: nil) == nil)
    }

    /// Giving the source back shows the pill the opening hid.
    @Test func releasingTheSourceShowsThePill() {
        let feed = makeFeed()
        feed.debugAuthorPillAlpha = 0
        feed.releaseProfileWindowSource()
        #expect(feed.debugAuthorPillAlpha == 1)
    }
}

/// A repository that vends nothing: these tests are about the pill.
private final class WindowSilentProvider: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry { throw CancellationError() }
}
