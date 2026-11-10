import CoreModels
import DesignSystem
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// FOR YOU'S PULL TAKES THE APP'S ONE RULE (#2235). The owner felt For You's
/// Feed page fire "as soon as I slide down from the top", next to Messages:
/// its control fired at UIKit's own distance, which moves with the list's
/// insets, and the page floats under a header. Its control now fires where
/// the shared rule says (`PullRefreshRule`), and the page refreshes only
/// then — or at once, from the failed state's "Try Again".
@MainActor
struct ForYouPullToRefreshTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func page() throws -> (ForYouGridPage, AppRefreshControl) {
        let page = ForYouGridPage(imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .discover)
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        page.layoutIfNeeded()
        let list = try #require(page.subviews.compactMap { $0 as? UICollectionView }.first)
        let control = try #require(list.refreshControl as? AppRefreshControl)
        control.minimumShown = 0
        return (page, control)
    }

    @Test func thePageRefreshesOnlyWhenTheSharedRuleFires() throws {
        let (page, control) = try page()
        var refreshes = 0
        page.onRefresh = { refreshes += 1 }

        control.debugFingerPull(to: PullRefreshRule.threshold - 1)
        #expect(refreshes == 0, "a pull let go short refreshed For You")

        // A fling's bounce past the threshold, no finger.
        for distance in stride(from: CGFloat(0), through: PullRefreshRule.threshold + 40, by: 10) {
            control.debugFollow(pulled: distance, isTracking: false)
        }
        control.debugFollow(pulled: 0, isTracking: false)
        #expect(refreshes == 0, "a bounce refreshed For You")

        control.debugFingerPull(to: PullRefreshRule.threshold)
        #expect(refreshes == 1, "a finger's pull to the threshold did not refresh For You")
        page.endRefreshing()
    }

    /// UIKit's own trigger — its distance, For You's insets and all — no
    /// longer refreshes the page by itself.
    @Test func uikitsOwnTriggerAloneDoesNotRefresh() throws {
        let (page, control) = try page()
        var refreshes = 0
        page.onRefresh = { refreshes += 1 }
        control.sendActions(for: .valueChanged)
        #expect(refreshes == 0, "UIKit's own trigger refreshed For You")
    }

    @Test func tryAgainRefreshesAtOnce() throws {
        let (page, _) = try page()
        var refreshes = 0
        page.onRefresh = { refreshes += 1 }
        page.retry()
        #expect(refreshes == 1)
    }
}
