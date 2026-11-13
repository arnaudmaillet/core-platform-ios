import CoreModels
import CoreStorage
import FeedInterface
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed
@testable import ThreadKit

/// A channel's "Share as a Post" opens the Text Post screen with its card
/// attached (#2216, part 3): the full card above the composer, removable —
/// the words then publish as a plain text post — and an optional place that
/// goes with the card.
@MainActor
struct ShowcaseComposerTests {
    private final class HeldFeed: FeedProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var held: [PostID: FeedEntry] = [:]

        func cachedFirstPage() async -> [FeedEntry]? { nil }
        func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
        func loadPage(afterToken token: String) async throws -> FeedPage {
            FeedPage(entries: [], nextPageToken: nil, isCold: false)
        }
        func loadPost(_ id: PostID) async throws -> FeedEntry {
            try lock.withLock {
                guard let entry = held[id] else { throw FeedError.transport(message: "unknown \(id)") }
                return entry
            }
        }
        nonisolated func peekPost(_ id: PostID) -> FeedEntry? { lock.withLock { held[id] } }
        func remember(_ entry: FeedEntry) async { lock.withLock { held[entry.post.id] = entry } }
    }

    private final class Viewer: CommentsProviding, @unchecked Sendable {
        let viewer = ViewerIdentity(name: "Demo Viewer", avatarURL: nil, profileID: ProfileID("prof-me"), handle: "you")
        nonisolated func cachedTopComments(for postID: PostID) -> [CommentEntry]? { [] }
        nonisolated func seedTopComments(_ entries: [CommentEntry], for postID: PostID) {}
        nonisolated func cachedViewerIdentity() -> ViewerIdentity? { viewer }
        func viewerIdentity() async -> ViewerIdentity? { viewer }
        func loadComments(for postID: PostID) async throws -> [CommentEntry] { [] }
        func addComment(_ body: String, to postID: PostID, parentID: String?, commentID: String) async throws -> CommentEntry {
            CommentEntry(id: "c", authorID: ProfileID("prof-me"), authorName: "Demo Viewer", authorHandle: "you", body: body, createdAt: Date())
        }
    }

    /// Records which publish the screen asked for.
    private final class Publisher: TextPostPublishing, @unchecked Sendable {
        enum Call: Equatable {
            case plain(String)
            case showcase(String, PostEmbed, TextPostPlace?)
        }
        private let lock = NSLock()
        private var recorded: [Call] = []
        var calls: [Call] { lock.withLock { recorded } }

        private func entry(_ text: String, embed: PostEmbed?, author: AuthorSummary?) -> FeedEntry {
            let by = author ?? AuthorSummary(id: ProfileID("prof-me"), handle: "you", displayName: "You", avatarURL: nil)
            return FeedEntry(
                post: Post(id: PostID("post-new"), authorID: by.id, caption: text, attachments: [], publishedAt: Date(), embed: embed),
                author: by
            )
        }

        func publishTextPost(_ text: String, as author: AuthorSummary?) async throws -> FeedEntry {
            lock.withLock { recorded.append(.plain(text)) }
            return entry(text, embed: nil, author: author)
        }

        func publishTextPost(
            _ text: String, embed: PostEmbed, place: TextPostPlace?, as author: AuthorSummary?
        ) async throws -> FeedEntry {
            lock.withLock { recorded.append(.showcase(text, embed, place)) }
            return entry(text, embed: embed, author: author)
        }
    }

    private struct Page {
        let window: UIWindow
        let navigation: UINavigationController
        let composer: TextPostComposerViewController
        let panel: PostDetailViewController
        let publisher: Publisher
    }

    private let embed = PostEmbed.channel(ChannelEmbed(
        conversationID: ConversationID("ch-daily"), name: "Daily light", description: "Tonight's light.",
        subscriberCount: 820, viewerState: .member
    ))
    private let bercy = TextPostPlace(name: "Skatepark de Bercy", latitude: 48.8349, longitude: 2.3814)

    private func openPage(attaching embed: PostEmbed?, showsEmbeds: Bool = true) throws -> Page {
        let publisher = Publisher()
        let draftsFile = "showcase-drafts-test-\(UUID().uuidString)"
        let pile = PostBookmarkStore(
            defaults: UserDefaults(suiteName: "showcase.bookmarks.tests.\(UUID().uuidString)")!,
            scope: StorageScope(owner: .member(account: "acc-1", profile: "prof-1"))
        )
        let screen = FeedFeatureBuilder(
            repository: HeldFeed(),
            commentsProvider: Viewer(),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            postDrafts: PostDraftStore(name: draftsFile)
        ).makeTextPostScreen(publisher: publisher, bookmarks: pile, attaching: embed, showsEmbeds: showsEmbeds)
        let navigation = try #require(screen as? UINavigationController)
        let composer = try #require(navigation.viewControllers.first as? TextPostComposerViewController)
        let window = UIWindow(frame: CGRect(origin: .zero, size: CGSize(width: 390, height: 844)))
        window.traitOverrides.preferredContentSizeCategory = .large
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        let panel = try #require(composer.children.first as? PostDetailViewController)
        return Page(window: window, navigation: navigation, composer: composer, panel: panel, publisher: publisher)
    }

    private func settle(until condition: () -> Bool) async throws {
        var attempts = 0
        while !condition(), attempts < 300 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func theComposerOpensWithTheFullCard() throws {
        let page = try openPage(attaching: embed)
        let attachment = try #require(page.composer.showcaseAttachment, "no card attached")
        #expect(attachment.card.embed == embed)
        #expect(attachment.card.size == .full)
        #expect(attachment.card.debugNameText == "Daily light")
        #expect(!attachment.card.isUserInteractionEnabled, "the card's Open would leave the sheet")
        #expect(attachment.isDescendant(of: page.composer.view))
        #expect(attachment.debugPlaceTitle == ShowcaseCopy.addPlace)
        #expect(!attachment.debugShowsClearPlace)
        #expect(page.composer.debugDraftShowcase == DraftShowcase(embed: embed, place: nil))
    }

    @Test func publishingSendsTheEmbedAndThePlace() async throws {
        let page = try openPage(attaching: embed)
        page.composer.setShowcasePlace(bercy)
        #expect(page.composer.showcaseAttachment?.debugPlaceTitle == "Skatepark de Bercy")
        #expect(page.composer.showcaseAttachment?.debugShowsClearPlace == true)
        page.panel.debugSend("The channel for tonight's light")
        try await settle { page.composer.debugIsPublished }
        #expect(page.publisher.calls == [.showcase("The channel for tonight's light", embed, bercy)])
        // The card is the post's now, drawn on its page: the attachment goes.
        #expect(page.composer.showcaseAttachment == nil)
    }

    @Test func clearingThePlacePublishesWithoutOne() async throws {
        let page = try openPage(attaching: embed)
        page.composer.setShowcasePlace(bercy)
        page.composer.showcaseAttachment?.debugClearPlace()
        page.panel.debugSend("No place")
        try await settle { page.composer.debugIsPublished }
        #expect(page.publisher.calls == [.showcase("No place", embed, nil)])
    }

    @Test func removingTheCardPublishesAPlainTextPost() async throws {
        let page = try openPage(attaching: embed)
        page.composer.setShowcasePlace(bercy)
        page.composer.showcaseAttachment?.debugRemove()
        #expect(page.composer.showcaseAttachment == nil)
        #expect(page.composer.debugDraftShowcase == nil, "the place went with the card")
        // A place with no card means nothing: it is the card's.
        page.composer.setShowcasePlace(bercy)
        #expect(page.composer.debugDraftShowcase == nil)
        page.panel.debugSend("Just words")
        try await settle { page.composer.debugIsPublished }
        #expect(page.publisher.calls == [.plain("Just words")])
    }

    /// `-channels` off: the screen opens plain, as the "+" menu's.
    @Test func withTheFlagOffNoCardIsAttached() async throws {
        let page = try openPage(attaching: embed, showsEmbeds: false)
        #expect(page.composer.showcaseAttachment == nil)
        #expect(page.composer.debugDraftShowcase == nil)
        page.panel.debugSend("Words")
        try await settle { page.composer.debugIsPublished }
        #expect(page.publisher.calls == [.plain("Words")])
    }

    /// The "+" menu's Text Post attaches nothing, flag on or off.
    @Test func thePlainScreenAttachesNothing() throws {
        let page = try openPage(attaching: nil)
        #expect(page.composer.showcaseAttachment == nil)
        #expect(page.navigation.sheetPresentationController?.selectedDetentIdentifier != .large)
    }

    @Test func aShowcaseOpensFullHeight() throws {
        let page = try openPage(attaching: embed)
        #expect(page.navigation.sheetPresentationController?.selectedDetentIdentifier == .large)
    }

    /// A draft with no showcase publisher ignores a showcase set on it.
    @Test func aDraftWithoutShowcasesPublishesPlainText() {
        let draft = PostDetailDraft { text, _ in
            FeedEntry(
                post: Post(id: PostID("p"), authorID: ProfileID("a"), caption: text, attachments: [], publishedAt: Date()),
                author: AuthorSummary(id: ProfileID("a"), handle: "a", displayName: "A", avatarURL: nil)
            )
        }
        #expect(draft.publishShowcase == nil)
    }
}
