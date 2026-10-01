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

    /// ⚠️ NO DATE ON THE PILL (asked 2026-10-01): its second line is the
    /// author's handle alone — the post's age is the post's, not the
    /// author's. So paging between two posts by one person changes nothing on
    /// it: same item, same words.
    @Test func thePillShowsTheHandleWithoutThePostsAge() throws {
        let (_, feed) = Self.feed()
        feed.showAuthor(Self.model(id: "p1", author: "Ada Lovelace", authorID: "prof-1", meta: "@ada · 2h"))
        let first = try #require(Self.authorItem(feed))
        let pill = try #require(first.customView)
        #expect(Self.labels(in: pill).contains("@ada"))
        #expect(!Self.labels(in: pill).contains { $0.contains("2h") || $0.contains("·") },
                "the pill still dates the post: \(Self.labels(in: pill))")

        feed.showAuthor(Self.model(id: "p2", author: "Ada Lovelace", authorID: "prof-1", meta: "@ada · 3d"))
        let second = try #require(Self.authorItem(feed))

        #expect(second === first)
        #expect(Self.labels(in: try #require(second.customView)).sorted() == ["@ada", "Ada Lovelace"])
    }

    /// The meta line's rule, alone: the handle, or nothing when a meta carries
    /// no handle (an age alone is still not the pill's to say).
    @Test func thePillsMetaLineIsTheHandleAlone() {
        #expect(SnapAuthorIdentityView.pillMetaLine(fromMeta: "@sam.whitfield · 28 May") == "@sam.whitfield")
        #expect(SnapAuthorIdentityView.pillMetaLine(fromMeta: "@ana") == "@ana")
        #expect(SnapAuthorIdentityView.pillMetaLine(fromMeta: "3m") == "")
        #expect(SnapAuthorIdentityView.pillMetaLine(fromMeta: "") == "")
    }

    /// Across authors the pill keeps what the host configured: its taps still
    /// route, and its width is the one the BAR's arithmetic set — the same for
    /// a two-letter name and a sentence (asked 2026-09-30: the glass must not
    /// change size between posts).
    @Test func thePillKeepsItsWiringAndItsWidthAcrossAuthors() throws {
        let (nav, feed) = Self.feed()
        // A real width to share out, as the screen's first layout pass has.
        nav.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        nav.view.layoutIfNeeded()
        let pill = try #require(Self.authorItem(feed)?.customView as? SnapAuthorIdentityView)
        let fixed = try #require(pill.fixedWidth, "the feed installed a pill that hugs its text")
        func fitted() -> CGFloat {
            pill.setNeedsLayout()
            pill.layoutIfNeeded()
            return pill.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        }

        for (id, name, meta) in [
            ("prof-1", "Al", "@al · 2h"),
            ("prof-2", "Grace Hopper With A Very Long Name Indeed", "@grace.hopper.the.admiral · 1d"),
            ("prof-3", "Ada Lovelace", "@ada · 3w"),
        ] {
            feed.showAuthor(Self.model(id: "p-\(id)", author: name, authorID: id, meta: meta))
            #expect(Self.authorItem(feed)?.customView === pill)
            #expect(abs(fitted() - fixed) < 0.5, "\(name): the pill took its text's width")
            #expect(pill.fixedWidth == fixed)
        }
        #expect(pill.onAuthorTapped != nil)
        #expect(pill.onFollowTapped != nil)
    }

    /// The follow glyphs share ONE slot, so a relation that changes (the "+"
    /// tapped into the followed mark) moves nothing in the pill.
    @Test func everyFollowBadgeIsDrawnInOneSlot() throws {
        let pill = SnapAuthorIdentityView()
        pill.setFixedWidth(200)
        pill.setAuthor(Self.model(id: "p1", author: "Ada Lovelace", authorID: "prof-1", meta: "@ada · 2h"),
                       pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), animated: false)
        var widths: [CGFloat] = []
        for badge in [SnapAuthorIdentityView.FollowBadge.follow, .following, .friends] {
            pill.setFollowBadge(badge)
            pill.setNeedsLayout()
            pill.layoutIfNeeded()
            widths.append(try #require(Self.firstButton(in: pill)).bounds.width)
        }
        #expect(
            widths.allSatisfy { abs($0 - SnapAuthorIdentityView.followBadgeSlotWidth) < 0.5 },
            "\(widths) vs slot \(SnapAuthorIdentityView.followBadgeSlotWidth)"
        )
    }

    private static func firstButton(in view: UIView) -> UIButton? {
        for sub in view.subviews {
            if let found = sub as? UIButton ?? firstButton(in: sub) { return found }
        }
        return nil
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
