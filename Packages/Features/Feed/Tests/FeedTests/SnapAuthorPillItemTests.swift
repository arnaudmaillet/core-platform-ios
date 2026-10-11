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
        feed.toolbarItems?.first { $0.customView is SnapAuthorIdentityView }
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
        let pills = (feed.toolbarItems ?? []).filter { $0.customView is SnapAuthorIdentityView }
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
        let after = Self.labels(in: try #require(second.customView))
        #expect(after.contains("@ada") && after.contains("Ada Lovelace"))
        #expect(!after.contains { $0.contains("3d") || $0.contains("·") }, "the pill dates the post: \(after)")
    }

    /// The meta line's rule, alone: the handle, or nothing when a meta carries
    /// no handle (an age alone is still not the pill's to say).
    @Test func thePillsMetaLineIsTheHandleAlone() {
        #expect(SnapAuthorIdentityView.pillMetaLine(fromMeta: "@sam.whitfield · 28 May") == "@sam.whitfield")
        #expect(SnapAuthorIdentityView.pillMetaLine(fromMeta: "@ana") == "@ana")
        #expect(SnapAuthorIdentityView.pillMetaLine(fromMeta: "3m") == "")
        #expect(SnapAuthorIdentityView.pillMetaLine(fromMeta: "") == "")
    }

    /// ⚠️ THE PILL TAKES ITS OWN WIDTH, CAPPED BY THE TOOLBAR (#925). Across
    /// authors it keeps what the host configured — its taps still route —
    /// and it is as wide as its face and its two lines: a short name gets a
    /// short pill, and a long one stops at the room the toolbar's trailing
    /// run leaves (`SnapBarPillWidths.toolbarAuthor`), truncating inside it.
    @Test func thePillHugsItsAuthorUnderTheToolbarsCap() throws {
        let (nav, feed) = Self.feed()
        // A real width to share out, as the screen's first layout pass has.
        nav.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        nav.view.layoutIfNeeded()
        let pill = try #require(Self.authorItem(feed)?.customView as? SnapAuthorIdentityView)
        let cap = SnapBarPillWidths.resolve(
            navBarWidth: 402, toolbarWidth: 402, walletWidth: nil, sort: nil
        ).toolbarAuthor
        #expect(abs(pill.widthCap - cap) < 0.5, "the cap is \(pill.widthCap), the toolbar leaves \(cap)")
        func fitted() -> CGFloat {
            pill.setNeedsLayout()
            pill.layoutIfNeeded()
            return pill.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        }

        var widths: [String: CGFloat] = [:]
        for (id, name, meta) in [
            ("prof-1", "Al", "@al · 2h"),
            ("prof-2", "Grace Hopper With A Very Long Name Indeed", "@grace.hopper.the.admiral · 1d"),
            ("prof-3", "Ada Lovelace", "@ada · 3w"),
        ] {
            feed.showAuthor(Self.model(id: "p-\(id)", author: name, authorID: id, meta: meta))
            #expect(Self.authorItem(feed)?.customView === pill)
            widths[id] = fitted()
        }
        let short = try #require(widths["prof-1"])
        let long = try #require(widths["prof-2"])
        let medium = try #require(widths["prof-3"])
        #expect(abs(long - cap) < 0.5, "a long name's pill is \(long), not the cap \(cap)")
        #expect(short < medium && medium < long, "the pill did not take its author's width: \(widths)")
        #expect(short < 100, "a two-letter name kept a wide pill: \(short)")
        #expect(pill.onAuthorTapped != nil)
        #expect(pill.onFollowTapped != nil)
    }

    /// ⚠️ THE BADGE IS ON THE AVATAR, NOT AT THE TRAILING END (#925): no
    /// relation moves the pill's width, and the badge sits over the face's
    /// bottom-right corner, a little outside it.
    @Test func theBadgeRidesTheAvatarAndNeverMovesTheWidth() throws {
        let pill = SnapAuthorIdentityView()
        pill.setAuthor(Self.model(id: "p1", author: "Ada Lovelace", authorID: "prof-1", meta: "@ada · 2h"),
                       pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), animated: false)
        var widths: [CGFloat] = []
        for badge in [SnapAuthorIdentityView.FollowBadge.none, .follow, .following, .friends] {
            pill.setFollowBadge(badge)
            pill.setNeedsLayout()
            pill.layoutIfNeeded()
            widths.append(pill.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width)
        }
        #expect(widths.allSatisfy { abs($0 - widths[0]) < 0.5 }, "the badge moved the pill's width: \(widths)")

        pill.frame.size = pill.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        pill.layoutIfNeeded()
        let badge = try #require(Self.firstButton(in: pill))
        let avatar = try #require(Self.firstView(of: MonogramAvatarView.self, in: pill))
        let badgeFrame = badge.convert(badge.bounds, to: pill)
        let face = avatar.convert(avatar.bounds, to: pill)
        #expect(badgeFrame.maxX > face.maxX && badgeFrame.midX < face.maxX,
                "not on the face's right edge: \(badgeFrame) vs \(face)")
        #expect(badgeFrame.maxY > face.maxY && badgeFrame.midY < face.maxY,
                "not on the face's bottom edge: \(badgeFrame) vs \(face)")
        let labels = Self.shownLabels(in: pill).map { $0.convert($0.bounds, to: pill) }
        #expect(!labels.isEmpty)
        #expect(labels.allSatisfy { $0.maxX <= pill.bounds.maxX + 0.5 }, "a label runs past the pill")
        #expect(badgeFrame.maxX <= (labels.map(\.minX).min() ?? .infinity),
                "the badge runs into the name: \(badgeFrame) vs \(labels)")
    }

    private static func firstButton(in view: UIView) -> UIButton? {
        for sub in view.subviews {
            if let found = sub as? UIButton ?? firstButton(in: sub) { return found }
        }
        return nil
    }

    private static func firstView<T: UIView>(of type: T.Type, in view: UIView) -> T? {
        for sub in view.subviews {
            if let found = sub as? T ?? firstView(of: type, in: sub) { return found }
        }
        return nil
    }

    private static func shownLabels(in view: UIView) -> [UILabel] {
        view.subviews.flatMap { sub -> [UILabel] in
            if let label = sub as? UILabel { return label.isHidden ? [] : [label] }
            // The face's own initials are not the pill's lines.
            return sub.isHidden || sub is MonogramAvatarView ? [] : shownLabels(in: sub)
        }
    }

    /// The pill is the toolbar's (#671): with a media post's thread open the
    /// ✕ takes the nav bar's slot, and the pill stays where it is, drawing
    /// an author change in place.
    @Test func anAuthorChangeWithTheThreadOpenIsDrawnInTheToolbar() throws {
        let (_, feed) = Self.feed()
        feed.showAuthor(Self.model(id: "p1", author: "Ada Lovelace", authorID: "prof-1", meta: "@ada · 2h"))
        let before = try #require(Self.authorItem(feed))
        feed.setEngagedChrome(true, hasMedia: true, animated: false)
        #expect(!(feed.navigationItem.rightBarButtonItems ?? []).contains { $0.customView is SnapAuthorIdentityView })

        feed.showAuthor(Self.model(id: "p2", author: "Grace Hopper", authorID: "prof-2", meta: "@grace · 1d"))
        let open = try #require(Self.authorItem(feed))
        #expect(open === before)
        #expect(Self.labels(in: try #require(open.customView)).contains("Grace Hopper"))
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
