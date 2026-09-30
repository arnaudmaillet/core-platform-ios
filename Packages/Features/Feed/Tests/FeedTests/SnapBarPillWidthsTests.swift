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

    /// The toolbar: the capsule the attribution shares with the mute button
    /// is the SAME width with and without the button, and the whole row fits.
    @Test(arguments: phoneWidths)
    func theAudioCapsuleKeepsItsWidthWithOrWithoutTheMuteButton(_ width: CGFloat) {
        let widths = SnapBarPillWidths.resolve(
            navBarWidth: width, toolbarWidth: width, walletWidth: Self.wallet, sort: nil
        )
        let slot = SnapBarPillWidths.soundSlot
        #expect(widths.attribution(soundShown: true) + slot == widths.attribution(soundShown: false))
        #expect(widths.attribution(soundShown: true) + SnapBarPillWidths.toolbarReserve <= width)
        #expect(widths.attribution(soundShown: true) > 0)
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
        #expect(author(402, wallet: Self.wallet) < author(402))
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

    /// Nothing pathological asks for a negative width.
    @Test func anImpossibleBarStillGetsABubble() {
        let widths = SnapBarPillWidths.resolve(
            navBarWidth: 200, toolbarWidth: 200, walletWidth: 180, sort: Self.sort
        )
        #expect(widths.author == SnapBarPillWidths.minimum)
        #expect(widths.attributionWithSound == SnapBarPillWidths.minimum)
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
        feed.showAttribution(model, sound: .sound("A Very Long Song Title Indeed · Somebody"), cover: .note)
        feed.setCommentSortAvailable(true)
        feed.setEngagedChrome(true, hasMedia: false, animated: false)
        for _ in 0..<30 {
            nav.view.setNeedsLayout()
            nav.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }

        let right = feed.navigationItem.rightBarButtonItems ?? []
        let left = feed.navigationItem.leftBarButtonItems ?? []
        let pill = try #require(right.compactMap { $0.customView as? SnapAuthorIdentityView }.first)
        let badge = try #require(right.compactMap { $0.customView as? WalletBadgeButton }.first)
        let sort = try #require(left.compactMap { $0.customView as? SnapCommentSortButton }.first)
        let toolbar = feed.toolbarItems ?? []
        let attribution = try #require(toolbar.compactMap { $0.customView as? SnapMediaAttributionView }.first)
        let more = try #require(
            toolbar.compactMap { $0.customView as? UIButton }.first { $0.accessibilityLabel == "More actions" }
        )

        for (name, view) in [("author", pill), ("wallet", badge), ("sort", sort),
                             ("attribution", attribution), ("more", more)] as [(String, UIView)] {
            #expect(view.window != nil, "\(width)pt: the \(name) item was folded away")
        }
        let fixed = try #require(pill.fixedWidth)
        #expect(abs(pill.bounds.width - fixed) < 1, "\(width)pt: the bar drew the pill \(pill.bounds.width), not \(fixed)")
        #expect(fixed >= 80, "\(width)pt: a pill of \(fixed) shows no name at all")
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
