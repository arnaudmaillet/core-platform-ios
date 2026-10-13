import CoreModels
import CoreStorage
import EntityStore
import MediaCore
import Testing
import UIKit
@testable import Feed

/// THE VERTICAL PAGE'S SAVE GLYPH FOLLOWS A SAVE MADE ELSEWHERE (#1067).
///
/// Since #1051 a post's saved state is one fact in the app's `EntityStore`,
/// written by the app's one `PostBookmarkStore`. The grids and cards redraw
/// on it; the vertical page read it only when the bars settled on a page, so
/// a save made on another surface while the page was on screen left the old
/// glyph up. Each test owns its store, its pile and its defaults suite: the
/// app's shared pile is never touched.
@MainActor
struct SnapSaveGlyphLiveTests {
    private struct Screen {
        let feed: SnapFeedViewController
        let entities: EntityStore
        /// The app's one pile, as the other surfaces write it.
        let pile: PostBookmarkStore
    }

    private static func makePile(over entities: EntityStore) -> PostBookmarkStore {
        let defaults = UserDefaults(suiteName: "snap.save-glyph.tests.\(UUID().uuidString)")!
        let pile = PostBookmarkStore(
            defaults: defaults, scope: StorageScope(owner: .member(account: "acc-1", profile: "prof-1"))
        )
        pile.facts = entities
        return pile
    }

    private static func makeFeed(entities: EntityStore, pile: PostBookmarkStore) -> SnapFeedViewController {
        SnapFeedViewController(
            viewModel: FeedViewModel(repository: SaveGlyphFeedProvider(), entities: entities),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            entities: entities,
            bookmarks: pile
        )
    }

    private static func openScreen() -> Screen {
        let entities = EntityStore()
        let pile = Self.makePile(over: entities)
        let feed = makeFeed(entities: entities, pile: pile)
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.pushViewController(feed, animated: false)
        feed.loadViewIfNeeded()
        return Screen(feed: feed, entities: entities, pile: pile)
    }

    /// The bars settle on `id` — what `updateBarChrome` does for the active
    /// page.
    private static func settleBars(on id: String, in screen: Screen) {
        screen.feed.refreshBookmarkGlyph(for: PostID(id))
    }

    @Test func theVerticalPageGlyphFollowsASaveMadeElsewhere() {
        let screen = Self.openScreen()
        Self.settleBars(on: "p1", in: screen)
        #expect(screen.feed.debugBookmarkGlyph.symbol == "bookmark", "precondition: not saved")

        // Another surface saves it — a card's save, a grid behind a sheet —
        // through the app's one pile, while the page is on screen.
        screen.pile.toggle("p1")
        #expect(screen.feed.debugBookmarkGlyph.symbol == "bookmark.fill", "the glyph fills at once")
        #expect(screen.feed.debugBookmarkGlyph.label == "Saved")

        screen.pile.toggle("p1")
        #expect(screen.feed.debugBookmarkGlyph.symbol == "bookmark", "and empties on an unsave")
        #expect(screen.feed.debugBookmarkGlyph.label == "Save")
    }

    /// Paged on: the glyph is the page's, and the page it left can no longer
    /// re-draw it — the observation follows the post the bars draw, never the
    /// one they drew before.
    @Test func afterPagingOnTheGlyphFollowsOnlyTheNewPage() {
        let screen = Self.openScreen()
        Self.settleBars(on: "p1", in: screen)
        Self.settleBars(on: "p2", in: screen)

        screen.pile.toggle("p1")
        #expect(screen.feed.debugBookmarkGlyph.symbol == "bookmark", "p1's save is not p2's glyph")

        screen.pile.toggle("p2")
        #expect(screen.feed.debugBookmarkGlyph.symbol == "bookmark.fill", "p2's is")

        // Back on p1, which was saved while off screen: drawn as it is now.
        Self.settleBars(on: "p1", in: screen)
        #expect(screen.feed.debugBookmarkGlyph.symbol == "bookmark.fill")
        screen.pile.toggle("p2")
        #expect(screen.feed.debugBookmarkGlyph.symbol == "bookmark.fill", "p2's unsave is not p1's glyph")
    }

    /// The observation is the page's own: it does not keep the page alive,
    /// and it goes with it (`EntityObservation` cancels on release) — a save
    /// made after the page left reaches nothing.
    @Test func theObservationEndsWithThePage() {
        let entities = EntityStore()
        let pile = Self.makePile(over: entities)
        weak var released: SnapFeedViewController?
        autoreleasepool {
            let feed = Self.makeFeed(entities: entities, pile: pile)
            feed.loadViewIfNeeded()
            feed.refreshBookmarkGlyph(for: PostID("p1"))
            released = feed
        }
        #expect(released == nil, "the observation kept the page alive")

        pile.toggle("p1")
        #expect(entities.isSaved(PostID("p1")) == true, "the save itself still lands")
    }
}

/// No pages, ever: the tests drive the bars directly.
private final class SaveGlyphFeedProvider: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        throw URLError(.fileDoesNotExist)
    }
}
