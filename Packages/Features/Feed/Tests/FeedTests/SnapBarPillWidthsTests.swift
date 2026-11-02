import CoreModels
import CoreStorage
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Feed

/// THE BAR PILLS HAVE FIXED WIDTHS, READ OFF THE BARS.
///
/// Asked 2026-09-30: the snap feed's author pill and audio capsule changed
/// width on every page, because they hugged their text. `SnapBarPillWidths`
/// is the arithmetic that replaced that — a function of the bars and the items
/// beside the pills, never of a post — and these pin it on every phone width
/// the app supports, down to the iPhone SE's 375pt, where a run one point too
/// wide is folded whole into UIKit's `•••`.
@MainActor
struct SnapBarPillWidthsTests {
    /// The comments' Popular | Recent selector as it draws (#2007).
    static var tabs: CGFloat { CommentTabsSelector().width }
    /// iPhone SE, the 6.1" and 6.3" phones, the Pro Max.
    nonisolated static let phoneWidths: [CGFloat] = [375, 393, 402, 440]

    /// The engaged bar (#2007): the leading bubble, the Popular | Recent
    /// selector and the wallet — the author is in the toolbar (#671), and the
    /// day pill takes what is left — fit every phone with the balance the
    /// badge draws most often (a "250", 71pt on the iPhone 18 Pro). The widest
    /// balance at the largest text size is checked on a real bar
    /// (`noPillIsFoldedAwayOnAPhone`).
    @Test(arguments: phoneWidths)
    func theEngagedRunWithTheTabsFitsEveryPhone(_ width: CGFloat) {
        let padding = SnapBarPillWidths.navItemPadding
        let spacing = SnapBarPillWidths.pillSpacing
        for wallet in [nil, 71] as [CGFloat?] {
            let run = SnapBarPillWidths.navBarMargin * 2
                + (SnapBarPillWidths.backButtonWidth + padding)
                + (spacing + Self.tabs + padding)
                + (wallet.map { $0 + padding + spacing } ?? 0)
            #expect(run + SnapBarPillWidths.slack <= width,
                    "\(width)pt, wallet \(wallet ?? 0), tabs \(Self.tabs): the run is \(run)")
        }
    }

    /// The toolbar: the author pill and the footer's stock items fit on every
    /// phone, at the default text size and at XXXL, whose glyph items are
    /// wider (#1679: measured 49 on the iPhone SE).
    @Test(arguments: phoneWidths)
    func theFooterRunFitsAtEveryTextSize(_ width: CGFloat) {
        for icon in [SnapBarPillWidths.defaultToolbarIcon, 49, 52] as [CGFloat] {
            let widths = SnapBarPillWidths.resolve(
                toolbarWidth: width, toolbarIcon: icon
            )
            #expect(widths.toolbarAuthor + SnapBarPillWidths.toolbarReserve(icon: icon) <= width,
                    "\(width)pt, icon \(icon): the footer run overflows")
            #expect(widths.toolbarAuthor >= 80, "\(width)pt, icon \(icon): a pill of \(widths.toolbarAuthor) shows no name")
        }
        // A larger text size only ever takes room from the pill.
        let base = SnapBarPillWidths.resolve(toolbarWidth: width)
        let large = SnapBarPillWidths.resolve(
            toolbarWidth: width, toolbarIcon: 49
        )
        #expect(large.toolbarAuthor < base.toolbarAuthor)
    }

    /// ⚠️ THE FOOTER AGAINST THE BAR AS MEASURED, NOT AGAINST ITSELF (#1679).
    /// The test host draws no Liquid Glass platters — its stock items come
    /// out narrower than a device's, so a fold the app shows never happens in
    /// a window here (checked: at 375pt and XXXL every item was hosted). So the
    /// gate is the run read off the app's own frames (`-dump-bars`, iPhone SE,
    /// iOS 27), literal here and never derived from `toolbarReserve`: 27.5pt
    /// margins, the pill's glass +10, 12.5pt gaps, ⋯'s 48, and the [☆ ⇄]
    /// platter — 107 at the default size; at XXXL ☆ alone measured 59 (49 +
    /// 10), so the two in one platter are 2 × 49 + 31.
    @Test(arguments: phoneWidths)
    func theFooterFitsTheRunTheAppDrew(_ width: CGFloat) {
        let measured: [(icon: CGFloat, platter: CGFloat)] = [(38, 107), (49, 129)]
        for (icon, platter) in measured {
            let pill = SnapBarPillWidths.resolve(
                toolbarWidth: width, toolbarIcon: icon
            ).toolbarAuthor
            let run = 27.5 + (pill + 10) + 12.5 + platter + 12.5 + 48 + 27.5
            #expect(run <= width, "\(width)pt, \(icon)pt glyphs: the footer is \(run) — ⇄ folds into •••")
            // The conversation's footer is the same run: [📷 🖼] for [☆ ⇄],
            // and a thread that sends no media wears ⋯ alone.
            let peer = width - SnapBarPillWidths.toolbarReserve(icon: icon, platter: true)
            #expect(27.5 + (peer + 10) + 12.5 + platter + 12.5 + 48 + 27.5 <= width)
            let textOnly = width - SnapBarPillWidths.toolbarReserve(icon: icon, platter: false)
            #expect(27.5 + (textOnly + 10) + 12.5 + 48 + 27.5 <= width)
        }
    }

    /// A text post's footer (#1924, #1999): `[author] [♥ n] [☆]` fits at the
    /// default size and at XXXL's glyphs, the pill at its face when the
    /// room is short — never folding into `•••`.
    @Test(arguments: phoneWidths)
    func theTextFooterFitsWithItsLike(_ width: CGFloat) {
        // Measured on the iPhone SE (`-open-post post-0002`): the like's
        // bubble 99pt at "382" and 102 at XXXL, ☆'s 48 at both — "999K" is
        // about 22 wider.
        let measured: [(icon: CGFloat, like: CGFloat)] = [(38, 121), (49, 125)]
        for (icon, like) in measured {
            let pill = SnapBarPillWidths.resolve(
                toolbarWidth: width,
                toolbarIcon: icon, toolbarLike: like
            ).toolbarAuthorBesideLike
            let run = 27.5 + (pill + 10) + 12.5 + like + 12.5 + 48 + 27.5
            #expect(run <= width, "\(width)pt, \(icon)pt glyphs: the text footer is \(run) — it folds into •••")
        }
    }

    /// ⚠️ THE PILL TAKES THE ROOM SHARE LEFT (#1999, the owner 2026-11-01):
    /// at the default size its budget clears the face-only threshold on
    /// every phone, so the name shows, truncated — no face alone with a hole
    /// before the heart. (`PersonPill.faceOnlyThreshold`: the face, its
    /// badge's overhang, the gaps and a few letters — about 100 pt.)
    @Test(arguments: phoneWidths)
    func theTextFootersPillShowsItsName(_ width: CGFloat) {
        let pill = SnapBarPillWidths.resolve(
            toolbarWidth: width,
            toolbarIcon: SnapBarPillWidths.defaultToolbarIcon, toolbarLike: 121
        ).toolbarAuthorBesideLike
        #expect(pill >= 100, "\(width)pt: the text footer's pill is \(pill) — its face alone")
    }

    /// Nothing pathological asks for a negative width.
    @Test func anImpossibleBarStillGetsABubble() {
        let widths = SnapBarPillWidths.resolve(toolbarWidth: 200)
        #expect(widths.toolbarAuthor == SnapBarPillWidths.minimum)
        #expect(widths.toolbarAuthorBesideLike == SnapBarPillWidths.minimum)
    }

    // MARK: - On a real bar

    /// ⚠️ THE FOLD, CHECKED WHERE IT HAPPENS. On every phone width, the feed
    /// in a window with its busiest bars — the wallet badge, a text page's
    /// thread with the Popular | Recent selector beside the back arrow (#2007),
    /// a long name and a long sound, at the default and the largest text size
    /// — hosts every item: the author pill, the badge and the selector in
    /// the navigation bar, the attribution and ⋯ in the toolbar. A custom view
    /// the bar swept into `•••` never reaches the window (its chain dead-ends
    /// at its item wrapper), which is what this reads.
    @Test(arguments: phoneWidths, [UIContentSizeCategory.large, .extraExtraExtraLarge])
    func noPillIsFoldedAwayOnAPhone(_ width: CGFloat, _ size: UIContentSizeCategory) async throws {
        let suite = "bar-pill-widths-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        // The widest balance the badge spells (`formattedCompact`): five
        // characters.
        let wallet = WalletStore(defaults: defaults)
        wallet.credit(88_800)
        let feed = SnapFeedViewController(
            viewModel: FeedViewModel(repository: InertPillFeedProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            wallet: wallet
        )
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.pushViewController(feed, animated: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 812))
        window.traitOverrides.preferredContentSizeCategory = size
        window.rootViewController = nav
        window.isHidden = false
        defer { window.isHidden = true }
        for _ in 0..<100 where feed.view.window == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        let model = FeedItemDisplayModel(
            id: PostID("p1"), authorID: ProfileID("prof-1"),
            authorName: "Maximilian Alexander Featherstonehaugh",
            metaText: "@maximilian.featherstonehaugh · 3w", avatarURL: nil,
            caption: "c", mediaURL: nil, mediaKind: .image, thumbnailURL: nil,
            audioText: "Original sound · @maximilian.featherstonehaugh"
        )
        feed.showAuthor(model)
        feed.setCommentTabsAvailable(true)
        feed.setEngagedChrome(true, hasMedia: false, animated: false)
        for _ in 0..<30 {
            nav.view.setNeedsLayout()
            nav.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }

        let right = feed.navigationItem.rightBarButtonItems ?? []
        let left = feed.navigationItem.leftBarButtonItems ?? []
        let badge = try #require(right.compactMap { $0.customView as? WalletBadgeButton }.first)
        let sort = try #require(left.compactMap { $0.customView as? PagedTabBar }.first)
        // The author pill leads the TOOLBAR (#671, the layout since #680).
        let toolbar = feed.toolbarItems ?? []
        let pill = try #require(toolbar.compactMap { $0.customView as? SnapAuthorIdentityView }.first)
        // The post's sound ends the bar (#1999, where Share was): a
        // container, so its view is the record itself.
        let more = try #require(
            toolbar.last { $0.identifier == SnapFooterToolbar.ID.sound }?.customView,
            "\(width)pt \(size.rawValue): the sound item was folded away"
        )

        for (name, view) in [("author", pill), ("wallet", badge), ("tabs", sort),
                             ("more", more)] as [(String, UIView)] {
            #expect(view.window != nil, "\(width)pt \(size.rawValue): the \(name) item was folded away")
        }
        // The pill hugs its content under the toolbar's cap (#925): a name
        // this long fills the cap, and the bar draws it at exactly that.
        let cap = pill.widthCap
        #expect(abs(pill.bounds.width - cap) < 1, "\(width)pt: the bar drew the pill \(pill.bounds.width), not its cap \(cap)")
        #expect(cap >= 80, "\(width)pt: a pill of \(cap) shows no name at all")
    }

    /// (#1681): the For You root's TOP bar on every phone —
    /// [bell][sort] … [pill][points], the busiest it gets (a text page's
    /// thread, a long name) — hosts every item: nothing folds into "•••".
    @Test(arguments: phoneWidths)
    func theForYouRootsTopBarFoldsNothingOnAPhone(_ width: CGFloat) async throws {
        let suite = "bar-pill-widths-root-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let feed = SnapFeedViewController(
            viewModel: FeedViewModel(repository: InertPillFeedProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            wallet: WalletStore(defaults: defaults)
        )
        feed.isForYouRoot = true
        let nav = UINavigationController(rootViewController: feed)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 812))
        window.rootViewController = nav
        window.isHidden = false
        defer { window.isHidden = true }
        for _ in 0..<100 where feed.view.window == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let bell = BarItems.icon(id: BarItems.SharedID.notificationsBell, image: UIImage(systemName: "bell"), label: "Notifications") {}
        feed.setLeadingAccessoryItem(bell)
        feed.showAuthor(FeedItemDisplayModel(
            id: PostID("p1"), authorID: ProfileID("prof-1"),
            authorName: "Maximilian Alexander Featherstonehaugh",
            metaText: "@maximilian.featherstonehaugh · 3w", avatarURL: nil,
            caption: "c", mediaURL: nil, mediaKind: .image, thumbnailURL: nil, audioText: nil
        ))
        feed.setCommentTabsAvailable(true)
        feed.setEngagedChrome(true, hasMedia: false, animated: false)
        for _ in 0..<30 {
            nav.view.setNeedsLayout()
            nav.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let right = feed.navigationItem.rightBarButtonItems ?? []
        let left = feed.navigationItem.leftBarButtonItems ?? []
        // No author pill in the top bar since #1699: it is inside the page.
        #expect(!right.contains { $0.customView is SnapAuthorIdentityView }, "\(width)pt: a pill in the root's top bar")
        let badge = try #require(right.compactMap { $0.customView as? WalletBadgeButton }.first)
        let sort = try #require(left.compactMap { $0.customView as? PagedTabBar }.first)
        for (name, view) in [("wallet", badge), ("tabs", sort)] as [(String, UIView)] {
            #expect(view.window != nil, "\(width)pt: the \(name) item was folded away")
        }
        #expect(left.first === bell, "\(width)pt: the bell does not lead")
        #expect(SnapActionColumnLayoutTests.hostedView(of: bell) != nil, "\(width)pt: the bell was folded away")
    }
}

/// No pages: the tests drive the bars directly.
private final class InertPillFeedProvider: FeedProviding, @unchecked Sendable {
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
