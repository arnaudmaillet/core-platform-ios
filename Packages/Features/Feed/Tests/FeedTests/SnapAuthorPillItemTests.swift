import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Feed

/// THE AUTHOR PILL IS ONE ITEM FOR THE SLOT.
///
/// It was an item per author under a per-author identifier, which bought iOS
/// 26's native item replacement — and a glass platter that morphed on every
/// page. Now the item, its identifier and its pill stay; a new author is drawn
/// IN PLACE, through the pill's own blur (`BarItemContentTransition`), and the
/// item is re-minted only invisibly (same pill, same identifier).
@MainActor
struct SnapAuthorPillItemTests {
    private static func feed() -> (nav: UINavigationController, feed: SnapFeedViewController) {
        let feed = SnapFeedViewController(
            viewModel: FeedViewModel(repository: PillFeedProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.pushViewController(feed, animated: false)
        feed.loadViewIfNeeded()
        return (nav, feed)
    }

    private static func model(
        id: String, author: String, authorID: String, meta: String
    ) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID(authorID),
            authorName: author, metaText: meta, avatarURL: nil,
            caption: "c", mediaURL: URL(string: "mock://media/1"),
            mediaKind: .image, thumbnailURL: nil, audioText: nil
        )
    }

    private static func authorItem(_ feed: SnapFeedViewController) -> UIBarButtonItem? {
        feed.navigationItem.rightBarButtonItems?.first { $0.customView is SnapAuthorIdentityView }
    }

    private static func labels(in view: UIView) -> [String] {
        view.subviews.flatMap { subview -> [String] in
            var found = labels(in: subview)
            if let label = subview as? UILabel, let text = label.text, !text.isEmpty { found.append(text) }
            return found
        }
    }

    @Test func aNewAuthorIsDrawnInTheSameItem() throws {
        let (_, feed) = Self.feed()
        feed.showAuthor(Self.model(id: "p1", author: "Ada Lovelace", authorID: "prof-1", meta: "@ada · 2h"))
        let first = try #require(Self.authorItem(feed))
        let firstPill = try #require(first.customView as? SnapAuthorIdentityView)

        feed.showAuthor(Self.model(id: "p2", author: "Grace Hopper", authorID: "prof-2", meta: "@grace · 1d"))
        let second = try #require(Self.authorItem(feed))
        let secondPill = try #require(second.customView as? SnapAuthorIdentityView)

        #expect(second === first, "a new item for a new author: iOS 26 morphs the glass between them")
        #expect(secondPill === firstPill)
        #expect(second.identifier == SnapFeedViewController.authorItemIdentifier)
        #expect(Self.labels(in: secondPill).contains("Grace Hopper"))
        #expect(Self.labels(in: secondPill).contains("Ada Lovelace") == false)
        // Exactly one author item in the run, however many authors went by.
        let pills = (feed.navigationItem.rightBarButtonItems ?? []).filter { $0.customView is SnapAuthorIdentityView }
        #expect(pills.count == 1)
    }

    /// Paging between two posts by one person only moves the post's age — no
    /// new identity to announce, so no new item.
    @Test func theSameAuthorKeepsTheItemAndMovesOnlyTheTime() throws {
        let (_, feed) = Self.feed()
        feed.showAuthor(Self.model(id: "p1", author: "Ada Lovelace", authorID: "prof-1", meta: "@ada · 2h"))
        let first = try #require(Self.authorItem(feed))

        feed.showAuthor(Self.model(id: "p2", author: "Ada Lovelace", authorID: "prof-1", meta: "@ada · 3d"))
        let second = try #require(Self.authorItem(feed))

        #expect(second === first)
        #expect(Self.labels(in: try #require(second.customView)).contains("@ada · 3d"))
    }

    /// Across authors the pill keeps what the host configured: its taps still
    /// route, and its width cap is the one the run arithmetic set.
    @Test func thePillKeepsTheHostsWiringAcrossAuthors() throws {
        let (_, feed) = Self.feed()
        feed.showAuthor(Self.model(id: "p1", author: "Ada Lovelace", authorID: "prof-1", meta: "@ada · 2h"))
        let first = try #require(Self.authorItem(feed)?.customView as? SnapAuthorIdentityView)
        first.setWidthBudget(120)

        feed.showAuthor(Self.model(id: "p2", author: "Grace Hopper With A Very Long Name",
                                   authorID: "prof-2", meta: "@grace · 1d"))
        let fresh = try #require(Self.authorItem(feed)?.customView as? SnapAuthorIdentityView)

        #expect(fresh.onAuthorTapped != nil)
        #expect(fresh.onFollowTapped != nil)
        fresh.setNeedsLayout()
        fresh.layoutIfNeeded()
        #expect(fresh.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width <= 120.5)
    }

    /// With a media post's thread open the ✕ holds the slot; an author change
    /// then must not push the pill back over it, and the new pill is what
    /// returns when the thread closes.
    @Test func anAuthorChangeUnderTheCloseButtonWaitsForTheSlot() throws {
        let (_, feed) = Self.feed()
        feed.showAuthor(Self.model(id: "p1", author: "Ada Lovelace", authorID: "prof-1", meta: "@ada · 2h"))
        feed.setEngagedChrome(true, hasMedia: true, animated: false)

        feed.showAuthor(Self.model(id: "p2", author: "Grace Hopper", authorID: "prof-2", meta: "@grace · 1d"))
        #expect(Self.authorItem(feed) == nil, "the pill replaced the close button")

        feed.setEngagedChrome(false, hasMedia: true, animated: false)
        let back = try #require(Self.authorItem(feed)?.customView)
        #expect(Self.labels(in: back).contains("Grace Hopper"))
    }

    /// The landing install: once the screen has appeared, the item that rode
    /// the presentation in is replaced by a fresh one showing the same author
    /// — what re-installing the item (the comments round trip) did on a device
    /// where the first one was drawn as a square.
    @Test func theItemIsReinstalledOnceTheScreenHasLanded() async throws {
        let (nav, feed) = Self.feed()
        feed.showAuthor(Self.model(id: "p1", author: "Ada Lovelace", authorID: "prof-1", meta: "@ada · 2h"))
        let rode = try #require(Self.authorItem(feed))

        // Showing the window is the appearance: willAppear arms the install,
        // didAppear (no flight) spends it.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = nav
        window.isHidden = false
        defer { window.isHidden = true }
        // The install is one turn after the landing, out of its completion.
        for _ in 0..<100 where Self.authorItem(feed) === rode {
            try await Task.sleep(for: .milliseconds(10))
        }

        let landed = try #require(Self.authorItem(feed))
        #expect(landed !== rode)
        // Same pill, same identifier: the swap is one item to the bar, unseen.
        #expect(landed.customView === rode.customView)
        #expect(landed.identifier == rode.identifier)
        #expect(Self.labels(in: try #require(landed.customView)).contains("Ada Lovelace"))
    }

    /// A pill (re)installed in the bar is a disc at its FIRST layout: the
    /// plate is its 32pt diameter, round by corner and by mask, before any
    /// later pass has had a chance to fix anything.
    @Test func theMonogramIsRoundAtTheFirstLayout() throws {
        let pill = SnapAuthorIdentityView()
        pill.setAuthor(Self.model(id: "p1", author: "Ursula Quinn", authorID: "prof-1", meta: "@uq · 2h"),
                       pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), animated: false)
        // The bar's wrapper: 36pt tall, the pill's fitted width.
        let size = pill.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let wrapper = UIView(frame: CGRect(x: 0, y: 0, width: size.width, height: 36))
        pill.frame = wrapper.bounds
        wrapper.addSubview(pill)
        wrapper.layoutIfNeeded()

        func monogram(in view: UIView) -> MonogramAvatarView? {
            for sub in view.subviews {
                if let found = sub as? MonogramAvatarView ?? monogram(in: sub) { return found }
            }
            return nil
        }
        let disc = try #require(monogram(in: pill))
        #expect(disc.bounds.size == CGSize(width: AvatarImageView.barDiameter, height: AvatarImageView.barDiameter))
        #expect(disc.layer.cornerRadius == AvatarImageView.barDiameter / 2)
        let mask = try #require(disc.layer.mask as? CAShapeLayer)
        #expect(mask.path == UIBezierPath(ovalIn: disc.bounds).cgPath)
        #expect(disc.debugMonogramText == "UQ")
    }
}

/// No pages, ever: the tests drive the pill directly.
private final class PillFeedProvider: FeedProviding, @unchecked Sendable {
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
