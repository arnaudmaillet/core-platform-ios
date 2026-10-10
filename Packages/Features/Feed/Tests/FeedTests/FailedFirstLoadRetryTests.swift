import CoreModels
import DesignSystem
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Feed

/// **A FAILED FIRST LOAD HAS A WAY OUT (#797).** The post opened full-screen
/// and the snap timeline both said "Pull to retry" over a screen with nothing
/// to pull — the post's refresh control lives on the collection its failure
/// hides, and the timeline has none. Each now shows the shared empty state
/// with Try Again; these pin that the action is there, that it reaches the
/// view model's reload, and that the content the reload brings replaces it.
///
/// The thread's twin is `ConversationThreadViewControllerTests.aFailedFirstLoadOffersTryAgain`.
@MainActor
struct FailedFirstLoadRetryTests {
    /// Fails until told to answer; counts every ask for the post and the
    /// timeline's first page.
    private final class FlakyFeed: FeedProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var answers = false
        private var postLoads = 0
        private var firstPageLoads = 0

        var postLoadCount: Int { lock.withLock { postLoads } }
        var firstPageLoadCount: Int { lock.withLock { firstPageLoads } }
        func startAnswering() { lock.withLock { answers = true } }

        func cachedFirstPage() async -> [FeedEntry]? { nil }
        func loadFirstPage() async throws -> FeedPage {
            let answering = lock.withLock {
                firstPageLoads += 1
                return answers
            }
            guard answering else { throw FeedError.transport(message: "offline") }
            return FeedPage(entries: [FailedFirstLoadRetryTests.entry()], nextPageToken: nil, isCold: false)
        }
        func loadPage(afterToken token: String) async throws -> FeedPage {
            FeedPage(entries: [], nextPageToken: nil, isCold: false)
        }
        func loadPost(_ id: PostID) async throws -> FeedEntry {
            let answering = lock.withLock {
                postLoads += 1
                return answers
            }
            guard answering else { throw FeedError.transport(message: "offline") }
            return FailedFirstLoadRetryTests.entry()
        }
    }

    nonisolated private static func entry() -> FeedEntry {
        FeedEntry(
            post: Post(
                id: PostID("post-1"), authorID: ProfileID("prof-1"), caption: "hello",
                attachments: [], publishedAt: Date(timeIntervalSince1970: 0)
            ),
            author: AuthorSummary(id: ProfileID("prof-1"), handle: "ava", displayName: "Ava Moreau", avatarURL: nil)
        )
    }

    /// Whether `condition` came to hold within `looks` short looks — a budget
    /// of looks, not of wall-clock time, so a starved runner spends none of it.
    private func settle(looks: Int = 1_000, until condition: () -> Bool) async -> Bool {
        for _ in 0..<looks {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// The screen's own status view: a direct subview, so a block nested in a
    /// list (the comment stream's empty state) is never mistaken for it.
    private func statusView(of screen: UIViewController) -> EmptyStateView? {
        screen.view.subviews.compactMap { $0 as? EmptyStateView }.first { !$0.isHidden }
    }

    private static func firstView<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstView(type, in: subview) { return match }
        }
        return nil
    }

    /// The failure's Try Again, checked live: shown, enabled, and worded.
    private func tryAgain(on screen: UIViewController) async throws -> UIButton {
        try #require(await settle { statusView(of: screen) != nil }, "the failure was not shown")
        let status = try #require(statusView(of: screen))
        let button = try #require(Self.firstView(UIButton.self, in: status))
        #expect(!button.isHidden)
        #expect(button.isEnabled)
        #expect(button.configuration?.title == "Try Again")
        return button
    }

    @Test func aFailedPostOffersTryAgainWhichReloadsIt() async throws {
        let feed = FlakyFeed()
        let viewModel = PostDetailViewModel(postID: PostID("post-1"), repository: feed)
        let screen = PostDetailViewController(
            viewModel: viewModel, imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        screen.loadViewIfNeeded()
        // Listens beside the screen, which keeps receiving every phase.
        var phases: [PostDetailViewModel.Phase] = []
        let render = viewModel.onPhaseChange
        viewModel.onPhaseChange = { phase in
            phases.append(phase)
            render?(phase)
        }
        screen.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        screen.view.layoutIfNeeded()

        let button = try await tryAgain(on: screen)
        #expect(feed.postLoadCount == 1)

        feed.startAnswering()
        button.sendActions(for: .primaryActionTriggered)

        #expect(await settle { feed.postLoadCount == 2 }, "Try Again did not reload the post")
        #expect(await settle { statusView(of: screen) == nil }, "the failure outlived the reload")
        guard case .content(let model)? = phases.last else {
            Issue.record("expected content, got \(String(describing: phases.last))")
            return
        }
        #expect(model.caption == "hello")
    }

    @Test func aFailedTimelineOffersTryAgainWhichReloadsIt() async throws {
        let feed = FlakyFeed()
        let viewModel = FeedViewModel(repository: feed)
        let screen = SnapFeedViewController(
            viewModel: viewModel,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            makeCommentsPanelContent: { _ in UIViewController() }
        )
        screen.loadViewIfNeeded()
        var states: [FeedViewModel.RenderState] = []
        let render = viewModel.onStateChange
        viewModel.onStateChange = { state in
            states.append(state)
            render?(state)
        }
        // The first load starts at the first layout with a width.
        screen.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        screen.view.layoutIfNeeded()

        let button = try await tryAgain(on: screen)
        #expect(feed.firstPageLoadCount == 1)

        feed.startAnswering()
        button.sendActions(for: .primaryActionTriggered)

        #expect(await settle { feed.firstPageLoadCount == 2 }, "Try Again did not reload the timeline")
        #expect(await settle { statusView(of: screen) == nil }, "the failure outlived the reload")
        #expect(states.last?.phase == .content)
        #expect(states.last?.items.map(\.id) == [PostID("post-1")])
    }
}
