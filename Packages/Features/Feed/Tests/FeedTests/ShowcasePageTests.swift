import CoreModels
import DesignSystem
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed
@testable import ThreadKit

/// A channel showcase's text page (#2216): the author's words, then the full
/// embed card; no comments — no comment rows, no input row — its like and
/// Share kept; and with the switch off, the plain text post it is.
@MainActor
struct ShowcasePageTests {
    private let embed = PostEmbed.channel(ChannelEmbed(
        conversationID: ConversationID("ch-harbour"), name: "Harbour notes", description: "Boats in, boats out.",
        subscriberCount: 10, visibility: .public, viewerState: .none
    ))

    private func entry(caption: String, embed: PostEmbed?) -> FeedEntry {
        FeedEntry(
            post: Post(id: PostID("p-showcase"), authorID: ProfileID("prof-1"), caption: caption, attachments: [],
                       publishedAt: Date(timeIntervalSince1970: 1_800_000_000), embed: embed),
            author: AuthorSummary(id: ProfileID("prof-1"), handle: "ava", displayName: "Ava Moreau", avatarURL: nil)
        )
    }

    // MARK: - The model

    @Test func theModelCarriesTheCardOnlyWithTheSwitch() {
        let on = PostDetailDisplayModel(entry: entry(caption: "Come aboard", embed: embed), showsEmbed: true)
        #expect(on.embed == embed)
        #expect(on.showsCaptionRow)
        #expect(!on.takesComments, "a showcase took comments")
        #expect(!on.hasMedia)
        let off = PostDetailDisplayModel(entry: entry(caption: "Come aboard", embed: embed), showsEmbed: false)
        #expect(off.embed == nil, "the switch off drew a card")
        #expect(off.takesComments)
        #expect(off.caption == "Come aboard", "the switch off lost the caption")
        let alone = PostDetailDisplayModel(entry: entry(caption: "", embed: embed), showsEmbed: true)
        #expect(alone.showsCaptionRow, "a card alone has no caption row")
    }

    // MARK: - The row

    @Test func theCaptionRowShowsTheWordsThenTheFullCard() throws {
        let cell = CaptionBubbleCell()
        cell.configure(with: PostDetailDisplayModel(entry: entry(caption: "Come aboard", embed: embed), showsEmbed: true),
                       imagePipeline: nil)
        let card = try #require(cell.debugEmbedView)
        #expect(card.size == .full)
        #expect(card.debugActionTitle == "Join")
        #expect(cell.debugShowsBody, "the author's words went")

        // A card alone: no empty line above it.
        cell.configure(with: PostDetailDisplayModel(entry: entry(caption: "", embed: embed), showsEmbed: true),
                       imagePipeline: nil)
        #expect(cell.debugEmbedView != nil && !cell.debugShowsBody)

        // The switch off, and a plain text post: today's row.
        cell.configure(with: PostDetailDisplayModel(entry: entry(caption: "Come aboard", embed: embed), showsEmbed: false),
                       imagePipeline: nil)
        #expect(cell.debugEmbedView == nil && cell.debugShowsBody)
        cell.configure(with: PostDetailDisplayModel(entry: entry(caption: "Just words", embed: nil), showsEmbed: true),
                       imagePipeline: nil)
        #expect(cell.debugEmbedView == nil)
    }

    /// The row is measured with the card: no jump when it lands.
    @Test func theRowIsMeasuredWithTheCard() {
        func height(_ embed: PostEmbed?) -> CGFloat {
            let cell = CaptionBubbleCell()
            cell.configure(with: PostDetailDisplayModel(entry: entry(caption: "Come aboard", embed: embed), showsEmbed: true),
                           imagePipeline: nil)
            cell.bounds.size.width = 390
            cell.contentView.layoutIfNeeded()
            return cell.contentView.systemLayoutSizeFitting(
                CGSize(width: 390, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
            ).height
        }
        #expect(height(embed) > height(nil) + 60, "the card took no room")
    }

    // MARK: - The page

    /// The post never arrives: the page runs on the seed, as it does while
    /// the post loads; the comments would, but the page shows none.
    private final class NoPostFeed: FeedProviding, @unchecked Sendable {
        func cachedFirstPage() async -> [FeedEntry]? { nil }
        func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
        func loadPage(afterToken token: String) async throws -> FeedPage {
            FeedPage(entries: [], nextPageToken: nil, isCold: false)
        }
        func loadPost(_ id: PostID) async throws -> FeedEntry {
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }
    }

    private final class SomeComments: CommentsProviding, @unchecked Sendable {
        let entries = (0..<3).map {
            CommentEntry(id: "c\($0)", authorID: ProfileID("prof-2"), authorName: "Ben", authorHandle: "ben",
                         body: "Comment \($0)", createdAt: Date())
        }
        nonisolated func cachedTopComments(for postID: PostID) -> [CommentEntry]? { entries }
        func loadComments(for postID: PostID) async throws -> [CommentEntry] { entries }
        func addComment(
            _ body: String, to postID: PostID, parentID: String?, commentID: String
        ) async throws -> CommentEntry {
            throw CommentsError.transport(message: "not used")
        }
    }

    private func page(seeding embed: PostEmbed?) async throws -> (PostDetailViewController, UICollectionView, UIWindow) {
        let controller = PostDetailViewController(
            viewModel: PostDetailViewModel(postID: PostID("p-showcase"), repository: NoPostFeed(),
                                           commentsProvider: SomeComments()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        controller.seedCaption("Come aboard", timestamp: "2h", authorName: "Ava Moreau", embed: embed)
        // The stream the page opens on: Popular for a post (#2287), whose
        // skeleton rows stand in until its first page lands — not the first
        // collection view in the hierarchy, which depends on the pager.
        // A showcase takes none and shows its caption alone, as before.
        let opening: UICollectionView = controller.showsPopular
            ? controller.popular.collectionView : controller.recent.collectionView
        let stream: UICollectionView = embed == nil
            ? opening : try #require(Self.firstView(UICollectionView.self, in: controller.view))
        // Give the comments time to land: a plain post shows them. A slow
        // runner keeps the skeleton longer (17 rows on CI after 1 s): wait
        // for the exact count, up to 10 s.
        var attempts = 0
        while attempts < 1000, embed == nil, stream.numberOfItems(inSection: 0) != 4 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        if embed != nil { try await Task.sleep(for: .milliseconds(200)) }
        stream.layoutIfNeeded()
        return (controller, stream, window)
    }

    @Test func aShowcasesPageHasItsCaptionAndNoComments() async throws {
        let (controller, stream, window) = try await page(seeding: embed)
        defer { window.isHidden = true }
        #expect(stream.numberOfSections == 1)
        #expect(stream.numberOfItems(inSection: 0) == 1, "a showcase showed comments")
        #expect(!controller.takesComments)
        let bar = try #require(Self.firstView(CommentsInputBar.self, in: controller.view))
        #expect(!bar.takesComments && !bar.debugShowsInputRow, "a showcase kept its input row")
        #expect(!bar.isHidden, "the like and Share went with the input row")
        let cell = try #require(Self.firstView(CaptionBubbleCell.self, in: stream))
        #expect(cell.debugEmbedView?.debugActionTitle == "Join")
    }

    @Test func aPlainTextPostKeepsItsComments() async throws {
        let (controller, stream, window) = try await page(seeding: nil)
        defer { window.isHidden = true }
        #expect(controller.takesComments)
        #expect(stream.numberOfItems(inSection: 0) == 4, "the caption, then the three comments")
        let bar = try #require(Self.firstView(CommentsInputBar.self, in: controller.view))
        #expect(bar.takesComments && bar.debugShowsInputRow)
    }

    private static func firstView<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstView(type, in: subview) { return match }
        }
        return nil
    }
}
