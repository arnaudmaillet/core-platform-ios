import CoreModels
import MediaCore
import Testing
import UIKit
@testable import Feed

/// A DISMISSAL SWIPE OWNS THE SCREEN, INCLUDING THE COMMENTS UNDER IT.
///
/// The full-surface pan that pops a text post lives on the feed's view, ABOVE
/// the comment stream, and the two recognise simultaneously. Freezing "the
/// content" for the gesture froze only the PAGER — right for a media post,
/// where the pager is all there is under the finger, and wrong for a text
/// post, which opens straight into a scroll view. A swipe with any vertical
/// component scrolled the comments while the page slid away.
///
/// Frozen rather than vetoed in the pan's delegate because the stream's own pan
/// may already have begun, and no begin-time veto stops a recognizer that is
/// already running.
@MainActor
struct CommentStreamScrollLockTests {
    private func detail() -> PostDetailViewController {
        let controller = PostDetailViewController(
            viewModel: PostDetailViewModel(
                postID: PostID("p"), repository: SilentFeedProvider()
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            mode: .commentsOnly
        )
        controller.loadViewIfNeeded()
        return controller
    }

    private func stream(of controller: PostDetailViewController) throws -> UICollectionView {
        try #require(Self.firstView(UICollectionView.self, in: controller.view))
    }

    private static func firstView<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstView(type, in: subview) { return match }
        }
        return nil
    }

    @Test func theStreamFreezesForTheGestureAndThawsAfterIt() throws {
        let controller = detail()
        let stream = try stream(of: controller)
        #expect(stream.isScrollEnabled)

        controller.setStreamScrollEnabled(false)
        #expect(stream.isScrollEnabled == false, "the comments scrolled during the swipe")

        controller.setStreamScrollEnabled(true)
        #expect(stream.isScrollEnabled, "the comments were left dead after the gesture")
    }

    /// The cancel path is the one that strands a screen. A drag released below
    /// the completion threshold leaves the post on display, and it has to be
    /// readable.
    @Test func aCancelledGestureLeavesTheStreamUsable() throws {
        let controller = detail()
        let stream = try stream(of: controller)

        controller.setStreamScrollEnabled(false)
        // Release below the threshold: same restore call, no pop.
        controller.setStreamScrollEnabled(true)

        #expect(stream.isScrollEnabled)
    }

    /// Restores what was THERE, not `true`. The stream is also frozen by the
    /// resting engagement's settle lock, and a swipe that begins and ends
    /// inside that window must not thaw it early — the gesture would hand back
    /// a scrollable stream the engagement is still holding still.
    @Test func aGestureInsideAnExistingFreezeDoesNotThawIt() throws {
        let controller = detail()
        let stream = try stream(of: controller)
        stream.isScrollEnabled = false   // the settle lock

        controller.setStreamScrollEnabled(false)
        controller.setStreamScrollEnabled(true)

        #expect(stream.isScrollEnabled == false,
                "the gesture thawed a stream something else was holding frozen")
    }

    /// Reentrancy: a gesture that reports its start twice must not record the
    /// frozen state as the value to restore, which would leave the stream dead
    /// for good.
    @Test func freezingTwiceStillThawsOnce() throws {
        let controller = detail()
        let stream = try stream(of: controller)

        controller.setStreamScrollEnabled(false)
        controller.setStreamScrollEnabled(false)
        controller.setStreamScrollEnabled(true)

        #expect(stream.isScrollEnabled)
    }

    /// …and a stray restore with no freeze outstanding changes nothing.
    @Test func anUnpairedThawIsANoOp() throws {
        let controller = detail()
        let stream = try stream(of: controller)
        stream.isScrollEnabled = false

        controller.setStreamScrollEnabled(true)

        #expect(stream.isScrollEnabled == false)
    }
}

/// A provider that answers nothing, so the stream exists without a fetch.
private final class SilentFeedProvider: FeedProviding, @unchecked Sendable {
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
                id: id, authorID: ProfileID("p"), caption: "hi",
                attachments: [], publishedAt: Date(timeIntervalSince1970: 0)
            ),
            author: AuthorSummary(
                id: ProfileID("p"), handle: "ava", displayName: "Ava", avatarURL: nil
            ),
            likeCount: 0
        )
    }
}
