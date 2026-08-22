import CoreModels
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// The two carousels — the card's and the post's — must show the same page at
/// every handshake between them.
///
/// ⚠️ The channel is an OPTIONAL for a reason, and that reason is the whole of
/// the defect these pin: an absent instruction and an instruction to go to page
/// ZERO are different things.
///
/// The post's carousel deliberately keeps its page across a re-configure that
/// carries the same attachments — without that, the second hydration a snap page
/// performs would yank a viewer's carousel back to page one 140ms after they
/// opened it. So "say nothing" means "stay", and a sender that skipped page zero
/// as a no-op was saying "stay" while meaning "go to the first page". The feed
/// controller is reused, so what it stayed on was the previous visit's page:
/// open page two, dismiss, open page one, and the post arrived on page two.
@MainActor
struct CarouselPageSyncTests {
    private func feed() -> SnapFeedViewController {
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: SilentFeedProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        controller.loadViewIfNeeded()
        return controller
    }

    /// ⚠️ ZERO IS AN INSTRUCTION. The case that was unsendable.
    @Test func pageZeroSurvivesTheChannel() {
        let controller = feed()
        let id = PostID("p")

        controller.openMediaPage(0, for: id)

        #expect(controller.consumeInitialMediaPage(for: id) == 0)
    }

    /// And every other page does too — asserted alongside zero rather than
    /// separately, because a channel that only carried zero would pass a test
    /// written for the bug and break everything else.
    @Test func anyPageSurvivesTheChannel() {
        let controller = feed()
        let id = PostID("p")

        for page in [0, 1, 2, 7] {
            controller.openMediaPage(page, for: id)
            #expect(controller.consumeInitialMediaPage(for: id) == page)
        }
    }

    /// ⚠️ Reading CLEARS it, and that is what makes "say nothing" mean "stay".
    ///
    /// A snap page configures twice on open — a seeded model, then the hydrated
    /// one — and both carry the same collection. The first configure consumes
    /// the instruction; the second must find none, or it would re-apply a page
    /// the viewer may already have scrolled away from.
    @Test func theInstructionIsConsumedOnce() {
        let controller = feed()
        let id = PostID("p")
        controller.openMediaPage(2, for: id)

        #expect(controller.consumeInitialMediaPage(for: id) == 2)
        #expect(controller.consumeInitialMediaPage(for: id) == nil)
    }

    /// An instruction is addressed to ONE post. A feed opens on a window of
    /// them, and the cells around the tapped one must not inherit its page.
    @Test func anInstructionIsNotDeliveredToAnotherPost() {
        let controller = feed()
        controller.openMediaPage(3, for: PostID("p"))

        #expect(controller.consumeInitialMediaPage(for: PostID("q")) == nil)
        // Still waiting for the post it was addressed to.
        #expect(controller.consumeInitialMediaPage(for: PostID("p")) == 3)
    }
}

/// A repository that vends nothing: these tests are about the page CHANNEL,
/// not about what a feed loads through it.
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
