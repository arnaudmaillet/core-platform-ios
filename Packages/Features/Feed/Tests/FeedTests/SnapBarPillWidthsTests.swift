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
    /// Widths on the generous side of what the feed hands in (iPhone 18 Pro,
    /// default text size: a "250" balance badge measured 71pt): a wider
    /// balance, and the comments sort with and without its word.
    static let wallet: CGFloat = 90
    static let sort = SnapBarPillWidths.Sort(glyph: 32, titled: 96)
    /// iPhone SE, the 6.1" and 6.3" phones, the Pro Max.
    nonisolated static let phoneWidths: [CGFloat] = [375, 393, 402, 440]

    /// Everything on the nav bar, laid end to end with UIKit's measured
    /// platters, fits the bar — the author pill included — at every width,
    /// in every composition the feed puts on it.
    @Test(arguments: phoneWidths)
    func theNavigationRunFitsEveryPhone(_ width: CGFloat) {
        let padding = SnapBarPillWidths.navItemPadding
        let spacing = SnapBarPillWidths.pillSpacing
        for wallet in [nil, Self.wallet] as [CGFloat?] {
            for sort in [nil, Self.sort] as [SnapBarPillWidths.Sort?] {
                let widths = SnapBarPillWidths.resolve(
                    navBarWidth: width, toolbarWidth: width, walletWidth: wallet, sort: sort
                )
                let sortWidth = sort.map { widths.sortShowsTitle ? $0.titled : $0.glyph }
                let run = SnapBarPillWidths.navBarMargin * 2
                    + (SnapBarPillWidths.backButtonWidth + padding)
                    + (sortWidth.map { spacing + $0 + padding } ?? 0)
                    + (wallet.map { $0 + padding + spacing } ?? 0)
                    + (widths.author + padding)
                #expect(run + SnapBarPillWidths.slack <= width,
                        "\(width)pt, wallet \(wallet ?? 0), sort \(sortWidth ?? 0): the run is \(run)")
                #expect(widths.author <= SnapBarPillWidths.authorCap)
                #expect(widths.author == widths.author.rounded(.down), "a fractional width is a pixel of drift")
                if sort == nil { #expect(widths.sortShowsTitle == false) }
            }
        }
    }

    /// The toolbar: the author pill and the footer's stock items fit on every
    /// phone, at the default text size and at XXXL, whose glyph items are
    /// wider (#1679: measured 49 on the iPhone SE).
    @Test(arguments: phoneWidths)
    func theFooterRunFitsAtEveryTextSize(_ width: CGFloat) {
        for icon in [SnapBarPillWidths.defaultToolbarIcon, 49, 52] as [CGFloat] {
            let widths = SnapBarPillWidths.resolve(
                navBarWidth: width, toolbarWidth: width, walletWidth: Self.wallet, sort: nil, toolbarIcon: icon
            )
            #expect(widths.toolbarAuthor + SnapBarPillWidths.toolbarReserve(icon: icon) <= width,
                    "\(width)pt, icon \(icon): the footer run overflows")
            #expect(widths.toolbarAuthor >= 80, "\(width)pt, icon \(icon): a pill of \(widths.toolbarAuthor) shows no name")
        }
        // A larger text size only ever takes room from the pill.
        let base = SnapBarPillWidths.resolve(navBarWidth: width, toolbarWidth: width, walletWidth: nil, sort: nil)
        let large = SnapBarPillWidths.resolve(
            navBarWidth: width, toolbarWidth: width, walletWidth: nil, sort: nil, toolbarIcon: 49
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
                navBarWidth: width, toolbarWidth: width, walletWidth: Self.wallet, sort: nil, toolbarIcon: icon
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

    /// What a pill's width depends on is the bars — and the one input that
    /// moves inside a screen's life is what else is on them. A narrower bar,
    /// a wallet, a sort: each only ever takes width away.
    @Test func theAuthorPillOnlyGivesWayToTheBar() {
        func author(_ width: CGFloat, wallet: CGFloat? = nil, sort: SnapBarPillWidths.Sort? = nil) -> CGFloat {
            SnapBarPillWidths.resolve(navBarWidth: width, toolbarWidth: width, walletWidth: wallet, sort: sort).author
        }
        #expect(author(440) == SnapBarPillWidths.authorCap, "a wide bar's pill stops at the cap")
        #expect(author(375) <= author(402))
        #expect(author(375, wallet: Self.wallet) < author(375))
        #expect(author(402, wallet: Self.wallet, sort: Self.sort) < author(402, wallet: Self.wallet))
        // Past a comfortable pill, the sort's word is what gives way.
        let tight = SnapBarPillWidths.resolve(
            navBarWidth: 375, toolbarWidth: 375, walletWidth: Self.wallet, sort: Self.sort
        )
        #expect(tight.sortShowsTitle == false)
        let roomy = SnapBarPillWidths.resolve(navBarWidth: 440, toolbarWidth: 440, walletWidth: nil, sort: Self.sort)
        #expect(roomy.sortShowsTitle)
        #expect(roomy.author >= SnapBarPillWidths.comfortableAuthor)
    }

    /// The author pill lost the post's age, and its width with it: one
    /// narrower cap, while the audio capsule — whose lines did not change —
    /// keeps the old one. On the iPhone 18 Pro with a "250" balance (71pt) the
    /// pill is the cap, no longer the bar's 193pt of room.
    @Test func theAuthorPillIsNarrowerThanTheAudioCapsuleCap() {
        #expect(SnapBarPillWidths.authorCap < SnapBarPillWidths.toolbarAuthorCap)
        #expect(SnapBarPillWidths.authorCap >= SnapBarPillWidths.comfortableAuthor)
        let pro = SnapBarPillWidths.resolve(navBarWidth: 402, toolbarWidth: 402, walletWidth: 71, sort: nil)
        #expect(pro.author == SnapBarPillWidths.authorCap)
        #expect(pro.author < 193)
    }

    /// Nothing pathological asks for a negative width.
    @Test func anImpossibleBarStillGetsABubble() {
        let widths = SnapBarPillWidths.resolve(
            navBarWidth: 200, toolbarWidth: 200, walletWidth: 180, sort: Self.sort
        )
        #expect(widths.author == SnapBarPillWidths.minimum)
        #expect(widths.toolbarAuthor == SnapBarPillWidths.minimum)
    }

    // MARK: - On a real bar

    /// ⚠️ THE FOLD, CHECKED WHERE IT HAPPENS. On every phone width, the feed
    /// in a window with its busiest bars — the wallet badge, a text page's
    /// thread with the sort beside the back arrow, a long name and a long
    /// sound — hosts every item: the author pill, the badge and the sort in
    /// the navigation bar, the attribution and ⋯ in the toolbar. A custom view
    /// the bar swept into `•••` never reaches the window (its chain dead-ends
    /// at its item wrapper), which is what this reads.
    @Test(arguments: phoneWidths)
    func noPillIsFoldedAwayOnAPhone(_ width: CGFloat) async throws {
        let suite = "bar-pill-widths-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let feed = SnapFeedViewController(
            viewModel: FeedViewModel(repository: InertPillFeedProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            wallet: WalletStore(defaults: defaults)
        )
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.pushViewController(feed, animated: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 812))
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
        feed.setCommentSortAvailable(true)
        feed.setEngagedChrome(true, hasMedia: false, animated: false)
        for _ in 0..<30 {
            nav.view.setNeedsLayout()
            nav.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }

        let right = feed.navigationItem.rightBarButtonItems ?? []
        let left = feed.navigationItem.leftBarButtonItems ?? []
        let badge = try #require(right.compactMap { $0.customView as? WalletBadgeButton }.first)
        let sort = try #require(left.compactMap { $0.customView as? SnapCommentSortButton }.first)
        // The author pill leads the TOOLBAR (#671, the layout since #680).
        let toolbar = feed.toolbarItems ?? []
        let pill = try #require(toolbar.compactMap { $0.customView as? SnapAuthorIdentityView }.first)
        // ⋯ is a stock item (#1679): its view is UIKit's.
        let more = try #require(
            toolbar.last { $0.accessibilityLabel == "More actions" }.flatMap(SnapActionColumnLayoutTests.hostedView(of:)),
            "\(width)pt: the more item was folded away"
        )

        for (name, view) in [("author", pill), ("wallet", badge), ("sort", sort),
                             ("more", more)] as [(String, UIView)] {
            #expect(view.window != nil, "\(width)pt: the \(name) item was folded away")
        }
        // The pill hugs its content under the toolbar's cap (#925): a name
        // this long fills the cap, and the bar draws it at exactly that.
        let cap = pill.widthCap
        #expect(abs(pill.bounds.width - cap) < 1, "\(width)pt: the bar drew the pill \(pill.bounds.width), not its cap \(cap)")
        #expect(cap >= 80, "\(width)pt: a pill of \(cap) shows no name at all")
    }

    /// EXPERIMENTAL (#1681): the For You root's TOP bar on every phone —
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
        feed.setCommentSortAvailable(true)
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
        let sort = try #require(left.compactMap { $0.customView as? SnapCommentSortButton }.first)
        for (name, view) in [("wallet", badge), ("sort", sort)] as [(String, UIView)] {
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
