import CoreModels
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Feed

/// A grab that is taking away a thread keeps the page on screen.
@MainActor
struct EngagedDismissalVisibilityTests {
    private func feed() -> SnapFeedViewController {
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: QuietFeedProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        controller.loadViewIfNeeded()
        return controller
    }

    /// ⚠️ THE HIDE ARRIVES AFTER THE GRAB HAS BEGUN, and that is the whole of
    /// this rule.
    ///
    /// `setZoomContentHidden(true)` is deferred by a commit and a display tick
    /// — deliberately, so the card is drawing before the page it replaces goes
    /// — which puts it AFTER the first pan events. An armed dismissal that
    /// only set the page visible once was overruled by it, and the thread
    /// vanished the instant the finger moved. Reported as exactly that, and
    /// invisible to a scripted grab: driving events continuously re-asserted
    /// the visibility on every frame and hid the defect.
    @Test func anArmedGrabRefusesTheDeferredHide() {
        let controller = feed()
        controller.debugArmEngagedDismissal()

        controller.setZoomContentHidden(true)

        #expect(controller.view.alpha == 1)
    }

    /// And an ordinary dismissal still hides — asserted beside it, because a
    /// page that never hides would satisfy the test above while breaking every
    /// flight that is not carrying a thread.
    @Test func anUnarmedDismissalStillHides() {
        let controller = feed()

        controller.setZoomContentHidden(true)

        #expect(controller.view.alpha == 0)
    }
}

/// A provider that answers nothing: this suite is about visibility, and a
/// controller with content would only add cells to lay out.
private final class QuietFeedProvider: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        FeedEntry(
            post: Post(
                id: id, authorID: ProfileID("p"), caption: "",
                attachments: [], publishedAt: Date(timeIntervalSince1970: 0)
            ),
            author: AuthorSummary(
                id: ProfileID("p"), handle: "ava", displayName: "Ava", avatarURL: nil
            ),
            likeCount: 0
        )
    }
}
