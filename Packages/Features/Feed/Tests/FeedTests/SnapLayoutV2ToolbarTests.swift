import CoreModels
import CoreStorage
import DesignSystem
import MediaCore
import MediaCoreFixtures
import PostGrid
import Testing
import UIKit
@testable import Feed
@testable import PostSurfaces
@testable import ThreadKit

/// **Full screen v2's toolbar (#2409), behind `-snap-layout-v2`.**
///
/// ```
///   not followed:  [◉ Tessa / @tessa] (  Follow  ) ———————— [⇄]
///   follows you:   [◉ Tessa / @tessa] (Follow back) ——————— [⇄]
///   tap:           [◉ Tessa / @tessa] (✓ Following) ——————— [⇄]   ~1 s
///   followed:      [◉✓ Tessa / ♪ Original sound · Tessa… ——] [⇄]
///   requested:     [◉ Tessa / @tessa] ( Requested ) ——————— [⇄]
/// ```
///
/// The Follow reads the same answer as the badge (`AuthorBadgeBinding`), so
/// the two never disagree. The top bar keeps no author pill. The share sheet
/// holds what ⋯ held, and Unfollow for an author the viewer follows. Flag off,
/// the other suites hold the classic bar unchanged.
@MainActor
struct SnapLayoutV2ToolbarTests {
    /// Lets the store's tasks move — bounded, never on the clock.
    private static func settle(until condition: () -> Bool) async {
        for _ in 0..<10_000 where !condition() {
            await Task.yield()
        }
    }

    private struct Screen {
        let feed: SnapFeedViewController
        let graph: V2FollowGraph
        let window: UIWindow?
        let clock: ManualLoadingClock
    }

    private static func screen(onScreen: Bool = false, v2: Bool = true) -> Screen {
        let graph = V2FollowGraph()
        let feed = SnapFeedViewController(
            viewModel: FeedViewModel(repository: V2ToolbarProvider(),
                                     unavailablePosts: UnavailablePosts(viewerEvents: ViewerEvents())),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            reporting: V2Reporter(),
            socialGraph: graph,
            followRelations: graph,
            bookmarks: PostBookmarkStore(scope: StorageScope()),
            savedSounds: SavedSoundStore(scope: StorageScope()),
            viewer: { ProfileID("me") }
        )
        feed.layoutV2 = v2
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.pushViewController(feed, animated: false)
        var window: UIWindow?
        if onScreen {
            let made = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            made.rootViewController = nav
            made.isHidden = false
            // The pushed page's view joins the window at the window's layout,
            // not at `isHidden` (iOS 26): only then is a change "seen".
            made.layoutIfNeeded()
            window = made
        }
        feed.loadViewIfNeeded()
        feed.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let screen = Screen(feed: feed, graph: graph, window: window, clock: ManualLoadingClock())
        feed.authorBar.follow.clock = screen.clock.clock
        return screen
    }

    private static func model(id: String = "p1", authorID: String = "tessa") -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID(authorID), authorName: "Tessa Lima",
            metaText: "@\(authorID) · 2h", avatarURL: nil, caption: "c",
            mediaURL: URL(string: "https://example.test/\(id).mp4"), mediaKind: .video,
            thumbnailURL: nil, audioText: nil, authorHandle: authorID
        )
    }

    private static func pill(_ feed: SnapFeedViewController) throws -> SnapAuthorIdentityView {
        try #require(feed.toolbarItems?.first?.customView as? SnapAuthorIdentityView)
    }

    private static func ids(_ feed: SnapFeedViewController) -> [String] {
        (feed.toolbarItems ?? []).compactMap(\.identifier)
    }

    private static func followItem(_ feed: SnapFeedViewController) -> UIBarButtonItem? {
        feed.toolbarItems?.first {
            [SnapToolbarFollow.followID, SnapToolbarFollow.requestedID, SnapToolbarFollow.confirmedID]
                .contains($0.identifier ?? "")
        }
    }

    // MARK: - The toolbar's items per relation

    @Test(arguments: [
        (FollowRelation.notFollowing, "Follow"),
        (.followedBy, "Follow back"),
    ])
    func aFollowInThePrimaryStandsBesideThePill(_ relation: FollowRelation, _ title: String) throws {
        let screen = Self.screen()
        let feed = screen.feed
        feed.followStore.setRelation(relation, for: ProfileID("tessa"))
        feed.authorBar.showAuthor(Self.model())

        let follow = try #require(Self.followItem(feed), "no Follow beside the pill: \(Self.ids(feed))")
        #expect(follow.identifier == SnapToolbarFollow.followID)
        #expect(follow.title == title)
        #expect(follow.style == .prominent, "Follow is not the page's filled control")
        #expect(follow.tintColor == Palette.primaryFill)
        #expect(feed.toolbarItems?.last?.identifier == SnapFooterToolbar.ID.repost)
        #expect(Self.ids(feed) == [
            SnapToolbarComposer.authorItemIdentifier(for: nil), SnapToolbarFollow.followID, SnapFooterToolbar.ID.repost,
        ], "not [pill] (Follow) ——— [⇄]: \(Self.ids(feed))")
        let pill = try Self.pill(feed)
        #expect(!pill.stretches)
        #expect(pill.secondLine == nil, "the second line is not the handle")
        #expect(pill.debugShownLines.last == "@tessa")
    }

    @Test func aPrivateAccountsRequestStaysQuietWithItsCancelMenu() throws {
        let screen = Self.screen()
        let feed = screen.feed
        feed.followStore.setRelation(.requested, for: ProfileID("tessa"))
        feed.authorBar.showAuthor(Self.model())

        let requested = try #require(Self.followItem(feed))
        #expect(requested.identifier == SnapToolbarFollow.requestedID)
        #expect(requested.title == "Requested")
        #expect(requested.style != .prominent, "Requested is filled")
        #expect(requested.menu?.children.map(\.title) == ["Cancel Request"])
        #expect(!(try Self.pill(feed).stretches))
    }

    /// Followed, a friend or the viewer's own post: no button; the pill takes
    /// the room up to the repost, its second line the sound.
    @Test(arguments: [FollowRelation.following, .mutual, .viewer])
    func aFollowedAuthorsPillStretchesToTheRepost(_ relation: FollowRelation) throws {
        let screen = Self.screen()
        let feed = screen.feed
        let author = relation == .viewer ? "me" : "tessa"
        feed.followStore.setRelation(relation, for: ProfileID(author))
        feed.authorBar.showAuthor(Self.model(authorID: author))

        #expect(Self.followItem(feed) == nil, "a button for \(relation)")
        #expect(Self.ids(feed) == [SnapToolbarComposer.authorItemIdentifier(for: nil), SnapFooterToolbar.ID.repost])
        let pill = try Self.pill(feed)
        #expect(pill.stretches, "the pill does not take the room")
        #expect(pill.secondLine?.hasPrefix("♪ ") == true, "the second line is not the sound: \(String(describing: pill.secondLine))")
    }

    /// Blocked, or a relation not known yet: no button, the handle.
    @Test func noButtonForABlockedOrUnknownAuthor() throws {
        let screen = Self.screen()
        let feed = screen.feed
        feed.followStore.setRelation(.blocked, for: ProfileID("tessa"))
        feed.authorBar.showAuthor(Self.model())
        #expect(Self.followItem(feed) == nil)
        #expect(!(try Self.pill(feed).stretches))
        feed.authorBar.showAuthor(Self.model(id: "p2", authorID: "unknown"))
        #expect(Self.followItem(feed) == nil)
        #expect(try Self.pill(feed).secondLine == nil)
    }

    /// One item for the screen's life: paging between authors keeps the
    /// pill and its item, under the slot's one identifier.
    @Test func pagingKeepsOnePillInOneItem() throws {
        let screen = Self.screen()
        let feed = screen.feed
        feed.followStore.setRelation(.notFollowing, for: ProfileID("tessa"))
        feed.followStore.setRelation(.following, for: ProfileID("ava"))
        feed.authorBar.showAuthor(Self.model())
        let item = try #require(feed.toolbarItems?.first)
        let pill = try Self.pill(feed)
        feed.authorBar.showAuthor(Self.model(id: "p2", authorID: "ava"))
        #expect(feed.toolbarItems?.first === item, "a new item for a new author")
        #expect(try Self.pill(feed) === pill)
        #expect(item.identifier == SnapToolbarComposer.authorItemIdentifier(for: nil))
        #expect(pill.shownAuthor?.authorID == ProfileID("ava"))
        #expect(pill.stretches)
        feed.authorBar.showAuthor(Self.model())
        #expect(!pill.stretches)
        #expect(Self.followItem(feed)?.title == "Follow")
    }

    // MARK: - Follow's tap

    /// A tap follows: the badge and the button read the same answer — "✓
    /// Following" for a moment, then the fold into the pill.
    @Test func followsTapConfirmsThenFoldsIntoThePill() async throws {
        let screen = Self.screen(onScreen: true)
        let feed = screen.feed
        // The confirmation is for a follow made where it can be seen.
        try #require(feed.view.window != nil, "the page is not on screen")
        feed.followStore.setRelation(.notFollowing, for: ProfileID("tessa"))
        feed.authorBar.showAuthor(Self.model())
        #expect(Self.followItem(feed)?.identifier == SnapToolbarFollow.followID)

        feed.authorBar.followShownAuthor()
        #expect(feed.followStore.relation(for: ProfileID("tessa")) == .following, "the tap did not follow")
        #expect(try Self.pill(feed).followBadge == .following)
        #expect(Self.followItem(feed)?.identifier == SnapToolbarFollow.confirmedID, "no ✓ Following")
        #expect(!(try Self.pill(feed).stretches), "the pill stretched before the confirmation")

        screen.clock.advance(AuthorFollowOffer.confirmationDuration)
        #expect(Self.followItem(feed) == nil, "the button did not fold")
        #expect(try Self.pill(feed).stretches)
        #expect(try Self.pill(feed).followBadge == .following)
        #expect(feed.authorBar.follow.offer == .following)
        await Self.settle { screen.graph.follows.count == 1 }
        #expect(screen.graph.follows == [ProfileID("tessa")])
        withExtendedLifetime(screen.window) {}
    }

    /// A private account: the button turns into Requested and stays.
    @Test func aPrivateAccountsFollowTurnsIntoRequested() async throws {
        let screen = Self.screen(onScreen: true)
        let feed = screen.feed
        screen.graph.outcome = .requested
        feed.followStore.setRelation(.notFollowing, for: ProfileID("tessa"))
        feed.authorBar.showAuthor(Self.model())
        feed.authorBar.followShownAuthor()
        await Self.settle { feed.followStore.relation(for: ProfileID("tessa")) == .requested }
        #expect(Self.followItem(feed)?.identifier == SnapToolbarFollow.requestedID)
        #expect(try Self.pill(feed).followBadge == .none)
        withExtendedLifetime(screen.window) {}
    }

    /// Requested's menu cancels the request: Follow is offered again.
    @Test func cancellingTheRequestOffersFollowAgain() async throws {
        let screen = Self.screen(onScreen: true)
        let feed = screen.feed
        feed.followStore.setRelation(.requested, for: ProfileID("tessa"))
        feed.authorBar.showAuthor(Self.model())
        feed.authorBar.cancelShownAuthorRequest()
        #expect(Self.followItem(feed)?.identifier == SnapToolbarFollow.followID)
        await Self.settle { screen.graph.withdrawals.count == 1 }
        #expect(screen.graph.withdrawals == [ProfileID("tessa")])
        withExtendedLifetime(screen.window) {}
    }

    // MARK: - The top bar and the share sheet

    /// The author pill is the toolbar's; the top bar holds the back item
    /// (and the balance, the owner's rule where likes move).
    @Test func theTopBarHoldsNoAuthorPill() throws {
        let screen = Self.screen()
        let feed = screen.feed
        feed.authorBar.showAuthor(Self.model())
        feed.setEngagedChrome(false, hasMedia: true, animated: false)
        let top = (feed.navigationItem.leftBarButtonItems ?? []) + (feed.navigationItem.rightBarButtonItems ?? [])
        #expect(!top.contains { $0.customView is SnapAuthorIdentityView }, "the author pill is still in the top bar")
        #expect((feed.navigationItem.leftBarButtonItems ?? []).allSatisfy {
            $0.identifier == SnapFeedViewController.backItemIdentifier
        })
        #expect(try Self.pill(feed).shownAuthor?.authorID == ProfileID("tessa"))
    }

    /// ⋯'s entries live in the share sheet (copy link and the system share
    /// are its own); Unfollow joins them for an author the viewer follows.
    @Test func theShareSheetHoldsWhatTheMenuHeldAndUnfollow() {
        let screen = Self.screen()
        let feed = screen.feed
        feed.seedProjection([Self.model()])
        feed.followStore.setRelation(.notFollowing, for: ProfileID("tessa"))
        #expect(feed.shareSheetActions(for: PostID("p1")).map(\.title) == ["Not interested", "Report"])
        feed.followStore.setRelation(.following, for: ProfileID("tessa"))
        #expect(feed.shareSheetActions(for: PostID("p1")).map(\.title) == ["Unfollow", "Not interested", "Report"])
        // Flag off: no Unfollow there.
        let classic = Self.screen(v2: false).feed
        classic.seedProjection([Self.model()])
        classic.followStore.setRelation(.following, for: ProfileID("tessa"))
        #expect(classic.shareSheetActions(for: PostID("p1")).map(\.title) == ["Not interested", "Report"])
    }

    /// Flag off: one item per author, the classic footer, no Follow. As on
    /// develop, the first author is drawn into the slot's own item, and the
    /// next author gets an item of its own, under its identifier (#1791).
    @Test func flagOffTheToolbarIsUnchanged() throws {
        let feed = Self.screen(v2: false).feed
        feed.followStore.setRelation(.notFollowing, for: ProfileID("tessa"))
        feed.authorBar.showAuthor(Self.model())
        #expect(Self.followItem(feed) == nil)
        let first = try #require(feed.toolbarItems?.first)
        #expect(first.identifier == SnapToolbarComposer.authorItemIdentifier(for: nil))
        #expect(Self.ids(feed).contains(SnapFooterToolbar.ID.save))
        #expect(!(try Self.pill(feed).stretches))
        feed.authorBar.showAuthor(Self.model(id: "p2", authorID: "ava"))
        #expect(feed.toolbarItems?.first !== first, "the next author kept the item")
        #expect(feed.toolbarItems?.first?.identifier == SnapToolbarComposer.authorItemIdentifier(for: ProfileID("ava")))
        #expect(Self.followItem(feed) == nil)
    }

    // MARK: - The pill

    /// The sound line opens the sound; the rest of the pill, the card.
    @Test func aTapOnTheSoundLineOpensTheSound() {
        let pill = SnapAuthorIdentityView()
        var sound = 0
        var card = 0
        pill.onSecondLineTapped = { sound += 1 }
        pill.onAuthorTapped = { _ in card += 1 }
        pill.setAuthor(Self.model(), pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
                       secondLine: "♪ Original sound · @tessa", animated: false)
        pill.frame = CGRect(x: 0, y: 0, width: 220, height: 40)
        pill.layoutIfNeeded()
        let line = pill.debugSecondLineFrame
        pill.debugTap(at: CGPoint(x: line.midX, y: line.midY))
        #expect(sound == 1 && card == 0, "the sound line did not open the sound")
        pill.debugTap(at: CGPoint(x: 8, y: 20))
        #expect(card == 1, "the face did not open the card")
    }

    /// ⚠️ NEVER `•••` (R4): on an iPhone SE at XXXL the pill's budget beside
    /// "Follow back" and the repost stays positive, its face at least.
    @Test func theSEAtXXXLLeavesThePillItsFace() {
        let traits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let icon = SnapBarPillWidths.toolbarIcon(for: traits)
        let follow = SnapToolbarFollow.followWidth(title: "Follow back", glyph: false, traits: traits)
        let budget = SnapToolbarFollow.pillBudget(toolbarWidth: 375, icon: icon, follow: follow)
        #expect(budget >= SnapBarPillWidths.minimum)
        let roomy = SnapToolbarFollow.pillBudget(toolbarWidth: 440, icon: SnapBarPillWidths.defaultToolbarIcon, follow: 90)
        #expect(roomy > budget)
    }
}

/// A follow graph that answers at once; it records follows and withdrawals.
@MainActor
private final class V2FollowGraph: SocialGraphReading, SocialGraphWriting {
    private(set) var follows: [ProfileID] = []
    private(set) var withdrawals: [ProfileID] = []
    var outcome: FollowOutcome = .following

    func followRelation(to profileID: ProfileID) async throws -> FollowRelation { .notFollowing }
    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {
        if following { follows.append(profileID) }
    }
    func follow(_ profileID: ProfileID) async throws -> FollowOutcome {
        follows.append(profileID)
        return outcome
    }
    func withdrawFollowRequest(to profileID: ProfileID) async throws {
        withdrawals.append(profileID)
    }
}

private struct V2Reporter: ContentReporting {
    func report(_ subject: ReportSubject, reason: ReportReason, surface: String) async throws {}
}

/// No pages: the tests drive the bars.
private final class V2ToolbarProvider: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry { throw URLError(.fileDoesNotExist) }
}
