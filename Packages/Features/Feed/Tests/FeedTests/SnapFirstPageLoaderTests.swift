import CoreModels
import MediaCore
import Testing
import UIKit
@testable import Feed

/// The launch screen with nothing to show yet (#1765): a first launch on Shots
/// — no page on the device — shows the centred loader, never a blank black
/// page, and the loader goes with the first page.
@MainActor
struct SnapFirstPageLoaderTests {
    private func feed(_ provider: any FeedProviding) -> SnapFeedViewController {
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: provider),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            reporting: SilentReporter()
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        return controller
    }

    @Test func aFeedWithNoPostYetShowsTheLoaderAfterTheGrace() async {
        let controller = feed(HangingProvider())
        #expect(!controller.debugShowsFirstPageLoader, "a loader before the grace")
        for _ in 0..<200 where !controller.debugShowsFirstPageLoader { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.debugShowsFirstPageLoader, "a blank page while the first page loads")
    }

    @Test func thePagesArrivalTakesTheLoaderDown() async {
        let controller = feed(EmptyProvider())
        // Past the grace, and the answer's render however late it lands on a
        // busy suite.
        try? await Task.sleep(for: .milliseconds(Int(SnapMediaWait.grace * 1000) + 100))
        for _ in 0..<300 where controller.debugShowsFirstPageLoader { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(!controller.debugShowsFirstPageLoader, "the loader outlived the answer")
    }
}

private final class SilentReporter: ContentReporting, @unchecked Sendable {
    func report(_ subject: ReportSubject, reason: ReportReason, surface: String) async throws {}
}

/// A first page that never comes.
private final class HangingProvider: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage {
        try await Task.sleep(nanoseconds: 60 * NSEC_PER_SEC)
        return FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPage(afterToken token: String) async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPost(_ id: PostID) async throws -> FeedEntry { throw FeedError.transport(message: "none") }
}

/// A first page that answers at once, empty.
private final class EmptyProvider: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPage(afterToken token: String) async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPost(_ id: PostID) async throws -> FeedEntry { throw FeedError.transport(message: "none") }
}
