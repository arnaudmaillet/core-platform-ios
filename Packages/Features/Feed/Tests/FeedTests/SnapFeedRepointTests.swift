import CoreContracts
import CoreModels
import DesignSystem
import Foundation
import MediaCore
import MediaPlayback
import Testing
import UIKit
@testable import Feed

/// Reuse across hero pushes: a feed that is re-aimed rather than rebuilt.
///
/// The push's stall is UIKit materialising bar glass, and a fresh controller
/// per tap is what keeps paying for it (see `ZoomFlightProfiler`). Re-pointing
/// removes the rebuild — but only safely if nothing describing the OLD window
/// survives into the new one, which is what these pin.
@MainActor
struct SnapFeedRepointTests {
    /// The guard that matters: a controller still on screen must never be
    /// re-aimed. Pushing it again would put the same instance in a navigation
    /// stack twice, and the caller's fallback (build a fresh one) is only
    /// reachable if this refuses honestly.
    @Test func repointRefusesWhileStillInANavigationStack() {
        let feed = Self.detachedFeed()
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.pushViewController(feed, animated: false)
        feed.loadViewIfNeeded()

        #expect(feed.repoint(to: [PostID("post-b")]) == false)
    }

    @Test func repointSucceedsOnceDetached() {
        let feed = Self.detachedFeed()
        feed.loadViewIfNeeded()

        #expect(feed.repoint(to: [PostID("post-b")]) == true)
    }

    /// Bar chrome held for a flight that never landed must not survive into
    /// the next push — a reused controller would otherwise be pushed wearing
    /// nothing, with its items stranded in the held set forever.
    @Test func repointReleasesChromeHeldByAnAbandonedFlight() {
        let feed = Self.detachedFeed()
        feed.loadViewIfNeeded()
        let resting = feed.navigationItem.rightBarButtonItems ?? []
        #expect(!resting.isEmpty)

        feed.holdBarChromeForFlight()
        #expect(feed.navigationItem.rightBarButtonItems ?? [] == [])

        feed.repoint(to: [PostID("post-b")])
        #expect(feed.navigationItem.rightBarButtonItems ?? [] == resting)
    }

    /// The pager goes back to the head of the window. The tapped post is
    /// always first, so a reused feed that kept its offset would open on
    /// whatever page the viewer left behind last time.
    @Test func repointReturnsThePagerToTheTop() {
        let feed = Self.detachedFeed()
        feed.loadViewIfNeeded()
        feed.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        feed.view.layoutIfNeeded()
        let collection = Self.collectionView(in: feed)
        collection?.setContentOffset(CGPoint(x: 0, y: 900), animated: false)
        #expect(collection?.contentOffset.y != 0)

        feed.repoint(to: [PostID("post-b")])

        #expect(collection?.contentOffset == .zero)
    }

    // MARK: - Helpers

    private static func detachedFeed() -> SnapFeedViewController {
        SnapFeedViewController(
            viewModel: FeedViewModel(repository: SilentFeedProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
    }

    private static func collectionView(in feed: SnapFeedViewController) -> UICollectionView? {
        feed.view.subviews.compactMap { $0 as? UICollectionView }.first
    }
}

/// Never answers, so nothing lands asynchronously mid-assertion — these tests
/// are about what `repoint` does to the controller, not about loading.
private final class SilentFeedProvider: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        throw FeedError.transport(message: "not used")
    }
}
