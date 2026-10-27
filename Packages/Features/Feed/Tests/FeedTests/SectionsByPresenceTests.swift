import CoreModels
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Feed

/// SECTIONS BY PRESENCE (#1773, the rule of #1756): no skeleton for a section
/// known to be empty — never bones that turn into an empty state.
@MainActor
struct SectionsByPresenceTests {
    private func detail() -> PostDetailViewController {
        let controller = PostDetailViewController(
            viewModel: PostDetailViewModel(postID: PostID("p"), repository: NoAnswerFeedProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.loadViewIfNeeded()
        return controller
    }

    @Test func aKnownCountCapsTheCommentBones() {
        #expect(SnapCommentsLayout.skeletonPlaceholderCount(viewportHeight: 844, knownComments: 0) == 0)
        #expect(SnapCommentsLayout.skeletonPlaceholderCount(viewportHeight: 844, knownComments: 3) == 3)
        let viewport = SnapCommentsLayout.skeletonPlaceholderCount(viewportHeight: 844)
        #expect(SnapCommentsLayout.skeletonPlaceholderCount(viewportHeight: 844, knownComments: 500) == viewport)
        #expect(SnapCommentsLayout.skeletonPlaceholderCount(viewportHeight: 844, knownComments: nil) == viewport)
    }

    @Test func aPostWithNoCommentsShowsNoCommentBones() {
        let controller = detail()
        #expect(controller.debugSkeletonRowCount > 0, "the premise: an unknown count wears bones")
        controller.seedCommentCount(0)
        #expect(controller.debugSkeletonRowCount == 0)
        controller.seedCommentCount(2)
        #expect(controller.debugSkeletonRowCount == 2)
    }
}

/// A provider whose post never answers in a test's time, so the stream stays
/// on its skeleton.
private final class NoAnswerFeedProvider: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage {
        try await Task.sleep(for: .seconds(60))
        return FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        try await Task.sleep(for: .seconds(60))
        return FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}
