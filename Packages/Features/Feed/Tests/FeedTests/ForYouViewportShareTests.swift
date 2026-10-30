import CoreModels
import CoreNavigation
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Feed

/// The For You grid under a screen pushed over it (#1914): its clips and its
/// rows play while it holds half the viewport, pause below, and come back at
/// half on the way back — the rule of every covered screen (`ViewportShare`).
@MainActor
struct ForYouViewportShareTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func screen() -> ForYouViewController {
        let screen = ForYouViewController(
            viewModel: ForYouViewModel(repository: EmptyForYou()),
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            makeSnapFeed: { _, _ in UIViewController() },
            prewarm: { _ in }
        )
        screen.loadViewIfNeeded()
        return screen
    }

    /// The gate reads the share: half and above plays, below pauses.
    @Test func theGridPlaysAtHalfAndAbove() {
        let screen = screen()
        #expect(screen.debugAutoplayIsActive)
        screen.debugViewportShare.report(0.6)
        #expect(screen.debugAutoplayIsActive, "the grid paused above half")
        screen.debugViewportShare.report(0.4)
        #expect(!screen.debugAutoplayIsActive, "the grid plays on under a screen past half")
        screen.debugViewportShare.report(0.5)
        #expect(screen.debugAutoplayIsActive, "the grid did not come back at half")
    }

    /// No transition to follow (a tab switch): stopped at once, and back at
    /// once, as before.
    @Test func aTabSwitchStopsAndRestartsAtOnce() {
        let screen = screen()
        screen.beginAppearanceTransition(false, animated: false)
        screen.endAppearanceTransition()
        #expect(!screen.debugAutoplayIsActive)
        screen.beginAppearanceTransition(true, animated: false)
        screen.endAppearanceTransition()
        #expect(screen.debugAutoplayIsActive)
    }
}

private final class EmptyForYou: ForYouProviding, @unchecked Sendable {
    func firstPage() async throws -> ForYouPage { ForYouPage(posts: [], nextPageToken: nil) }
    func page(after token: String) async throws -> ForYouPage { ForYouPage(posts: [], nextPageToken: nil) }
}
