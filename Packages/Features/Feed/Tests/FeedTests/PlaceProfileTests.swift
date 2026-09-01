import CoreModels
import CoreStorage
import DesignSystem
import FeedInterface
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// The PLACE PROFILE: a hero banner wearing the top post, aggregated
/// Reactions/Views, three tabs (Gallery by popularity, Shorts, chronological
/// Activity), and the follow toggle in its header.
@MainActor
struct PlaceProfileTests {
    private func post(
        _ id: String,
        kind: GalleryPost.Kind = .photo,
        reactions: Int64? = nil,
        views: Int64? = nil,
        publishedAtMS: Int64 = 0,
        author: String? = nil,
        thumbnail: String? = nil
    ) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: kind, isRepost: false,
            thumbnailURL: thumbnail.flatMap { URL(string: $0) },
            caption: "", publishedAtMS: publishedAtMS,
            authorName: author,
            reactionCount: reactions, viewCount: views
        )
    }

    private func makeProfile(
        following: ClusterGalleryFollowing? = nil,
        wallet: WalletStore? = nil,
        posts: [GalleryPost] = []
    ) -> PlaceProfileViewController {
        PlaceProfileViewController(
            postIDs: posts.map(\.id),
            placeName: "Paris • City Cluster",
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: nil,
            following: following,
            wallet: wallet,
            loadPosts: { posts },
            openPost: { _, _, _ in }
        )
    }

    /// A defaults suite of this test's own: `WalletStore` persists there, and
    /// a shared one would let two runs read each other's balance.
    private static func makeWalletDefaults() -> UserDefaults {
        UserDefaults(suiteName: "place-profile-wallet-\(UUID().uuidString)") ?? .standard
    }

    // MARK: - Popularity ordering (the Gallery tab's contract)

    /// The profile's one ordering is popularity DESCENDING — the trending
    /// rule verbatim, so ties fall to recency then id and a re-render can't
    /// reshuffle equals.
    @Test func theGalleryRanksByPopularityDescending() {
        let ranked = PlaceProfileViewController.ranked([
            post("post-1", reactions: 40),
            post("post-2", reactions: 900),
            post("post-3", reactions: nil), // no counter → ranks as 0, last
            post("post-4", reactions: 90),
        ])
        #expect(ranked.map(\.id.rawValue) == ["post-2", "post-4", "post-1", "post-3"])
    }

    /// And the hydration path renders THROUGH that order: whatever order the
    /// members arrive in, the Gallery grid's content is popularity-first.
    @Test func hydrationRendersInRankedOrder() async {
        let profile = makeProfile(posts: [
            post("post-1", reactions: 5),
            post("post-2", reactions: 70),
            post("post-3", reactions: 20),
        ])
        profile.beginLoading()
        for _ in 0..<50 where profile.renderedPosts.isEmpty { await Task.yield() }
        #expect(profile.renderedPosts.map(\.id.rawValue) == ["post-2", "post-3", "post-1"])
    }

    // MARK: - Banner and metrics

    /// The hero banner wears the RANKING's top post — the same post the
    /// cluster pin's face and the Gallery's first tile show.
    @Test func theBannerWearsTheTopRankedPost() {
        let ranked = PlaceProfileViewController.ranked([
            post("post-1", reactions: 12, thumbnail: "mock://cover-1"),
            post("post-2", reactions: 480, thumbnail: "mock://cover-2"),
        ])
        #expect(PlaceProfileViewController.bannerPost(in: ranked)?.id == PostID("post-2"))
        #expect(PlaceProfileViewController.bannerPost(in: []) == nil)
    }

    /// The metric band's two numbers are straight sums; a counter the
    /// read-model never projected counts as zero, never poisons the total.
    @Test func metricsAggregateReactionsAndViews() {
        let totals = PlaceProfileViewController.aggregatedMetrics(of: [
            post("post-1", reactions: 100, views: 1_000),
            post("post-2", reactions: 40, views: nil),
            post("post-3", reactions: nil, views: 500),
        ])
        #expect(totals.reactions == 140)
        #expect(totals.views == 1_500)
    }

    // MARK: - Activity

    /// The Activity tab is CHRONOLOGICAL, newest first — the one surface of
    /// the page that is not popularity — and it carries EVERY kind: a
    /// place's activity is its posts, so words, stills and video all travel.
    @Test func activityIsNewestFirstAndKeepsEveryKind() {
        let recent = PlaceProfileViewController.chronological([
            post("post-1", kind: .photo, publishedAtMS: 1_000),
            post("post-2", kind: .text, publishedAtMS: 3_000),
            post("post-3", kind: .video, publishedAtMS: 2_000),
        ])
        #expect(recent.map(\.id.rawValue) == ["post-2", "post-3", "post-1"])
        #expect(Set(recent.map(\.kind)) == [.photo, .text, .video],
                "no kind is filtered out — the cards show what For You's own card tab shows")
    }

    /// The whole fan-out through one hydration: both tabs populated from one
    /// corpus, each under its own rule — popularity on Discover, recency on
    /// Activity — so the two can only ever disagree about ORDER.
    @Test func oneHydrationFansOutToBothTabs() async {
        let profile = makeProfile(posts: [
            post("post-1", kind: .photo, reactions: 50, publishedAtMS: 1_000),
            post("post-2", kind: .video, reactions: 90, publishedAtMS: 2_000),
            post("post-3", kind: .text, reactions: 10, publishedAtMS: 3_000),
        ])
        profile.beginLoading()
        for _ in 0..<50 where profile.renderedPosts.isEmpty { await Task.yield() }
        #expect(profile.renderedPosts.map(\.id.rawValue) == ["post-2", "post-1", "post-3"])
        #expect(profile.renderedActivity.map(\.id.rawValue) == ["post-3", "post-2", "post-1"])
        #expect(Set(profile.renderedActivity.map(\.id)) == Set(profile.renderedPosts.map(\.id)),
                "one corpus, two orders")
        #expect(profile.tabTitles == ["Discover", "Activity"])
    }

    // MARK: - The follow toggle

    /// The header's trailing button mirrors the injected state and flips it:
    /// Follow → toggle → Following → toggle → Follow, always reading the
    /// caller's answer rather than caching its own.
    @Test func theFollowButtonTogglesTheInjectedState() throws {
        var followed = false
        let profile = makeProfile(following: ClusterGalleryFollowing(
            isFollowing: { followed },
            toggle: { followed.toggle(); return followed }
        ))
        profile.loadViewIfNeeded()

        // The heart alone carries the state — no word rides beside it, so the
        // FILL is what a test reads and what a viewer sees.
        let item = try #require(profile.navigationItem.rightBarButtonItems?.first)
        #expect(item.title == nil, "a titled item would be charged its word against the bar")
        #expect(item.image == UIImage(systemName: "heart"))
        #expect(item.accessibilityLabel == "Follow this place")

        let action = try #require(item.primaryAction)
        action.performWithSender(nil, target: nil)
        #expect(followed, "the toggle reached the caller's store")
        #expect(item.image == UIImage(systemName: "heart.fill"))
        #expect(item.accessibilityLabel == "Unfollow this place")

        action.performWithSender(nil, target: nil)
        #expect(!followed)
        #expect(item.image == UIImage(systemName: "heart"))
    }

    /// Each trailing item earns its place from a seam: no follow closure, no
    /// heart; no wallet, no balance. An inert control would promise a feature
    /// the caller cannot honor.
    @Test func trailingItemsAppearOnlyWithTheirSeams() {
        let bare = makeProfile(following: nil)
        bare.loadViewIfNeeded()
        #expect((bare.navigationItem.rightBarButtonItems ?? []).isEmpty)

        let followable = makeProfile(following: ClusterGalleryFollowing(
            isFollowing: { false }, toggle: { true }
        ))
        followable.loadViewIfNeeded()
        #expect(followable.navigationItem.rightBarButtonItems?.count == 1)
    }

    /// The trailing pair, in the order the eye reads it: [points][♡]. Index 0
    /// is the RIGHTMOST item, so the heart keeps the corner it has always had
    /// and the balance sits inboard of it — the order the map already puts
    /// its coin inboard of the bell.
    @Test func thePointsBalanceSitsInboardOfTheHeart() throws {
        let profile = makeProfile(
            following: ClusterGalleryFollowing(isFollowing: { false }, toggle: { true }),
            wallet: WalletStore(defaults: Self.makeWalletDefaults())
        )
        profile.loadViewIfNeeded()
        let items = try #require(profile.navigationItem.rightBarButtonItems)
        #expect(items.count == 2)
        #expect(items[0].image == UIImage(systemName: "heart"), "the corner is the heart's")
        #expect(items[1].customView is WalletBadgeButton)
        #expect(items[1].accessibilityLabel == "Points balance")
        // ⚠️ Each in its OWN bubble. Sharing the group's one platter is what
        // makes two controls read as a segmented pair — the map's coin and
        // bell, the profile's tray and For You's all opt out the same way.
        #expect(items.allSatisfy { !$0.sharesBackground })
    }

    /// The selector docks into the navigation bar's LEADING group, beside the
    /// back chevron, and the inline copy owns the un-scrolled state. Both
    /// copies exist from the start — the hand-over is a crossfade, which is
    /// not a state one re-parented view can express.
    @Test func theSelectorHandsOverToTheBarAtTheDockLine() {
        let profile = makeProfile()
        profile.loadViewIfNeeded()
        profile.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        profile.view.layoutIfNeeded()

        #expect(!profile.debugIsBarDocked, "expanded: the inline copy owns it")
        #expect(profile.debugInlineSelectorAlpha == 1)
        #expect(!profile.debugDockedSelectorItemPresent,
                "…and the bar item is absent, not merely transparent")

        profile.debugScrollActivePage(to: profile.debugHeaderTravel + 40)
        #expect(profile.debugIsBarDocked)
        #expect(profile.debugDockedSelectorItemPresent)
        #expect(profile.debugDockedSelectorAlpha == 1)
    }

    // MARK: - The collapsible header's coordinator rules

    /// The alignment rule that keeps the header still across tab switches —
    /// the profile pager's, verbatim: below the dock line the offset belongs
    /// to the SCREEN (every page must agree); above it, to the TAB (its own
    /// place, floored at the first row under the chrome).
    @Test func alignedOffsetSharesBelowTheDockLineAndFreesAbove() {
        // Below the line: every page takes the screen's number, even one
        // that had its own.
        #expect(PlaceProfileViewController.alignedOffset(
            current: 120, pageOwn: 300, dockLine: 227, contentFloor: 281
        ) == 120)
        // Above it: the tab keeps its own place...
        #expect(PlaceProfileViewController.alignedOffset(
            current: 500, pageOwn: 400, dockLine: 227, contentFloor: 281
        ) == 400)
        // ...but never above the floor that would leave its first row under
        // the chrome.
        #expect(PlaceProfileViewController.alignedOffset(
            current: 500, pageOwn: 0, dockLine: 227, contentFloor: 281
        ) == 281)
        // Degenerate geometry (nothing to dock) shares everywhere.
        #expect(PlaceProfileViewController.alignedOffset(
            current: 500, pageOwn: 0, dockLine: 0, contentFloor: 0
        ) == 500)
    }

    /// The identity fade is position-driven and lands at exactly zero on the
    /// dock line — where the metrics would otherwise draw through the
    /// transparent navigation bar.
    @Test func identityFadesOutExactlyAtTheDock() {
        #expect(PlaceProfileViewController.identityAlpha(travelled: 0, dockLine: 227) == 1)
        #expect(PlaceProfileViewController.identityAlpha(travelled: 227, dockLine: 227) == 0)
        #expect(PlaceProfileViewController.identityAlpha(travelled: 187, dockLine: 227) == 0.5)
        #expect(PlaceProfileViewController.identityAlpha(travelled: 300, dockLine: 227) == 0,
                "past the dock stays gone, never negative")
        #expect(PlaceProfileViewController.identityAlpha(travelled: -80, dockLine: 227) == 1,
                "overscroll stays opaque, never over 1")
    }

    /// The whole mechanism, window-hosted: scrolling the active page collapses
    /// the header (its top constraint follows the offset), stops at the dock
    /// line, and comes back — and a pull-down carries the header below rest.
    @Test func theHeaderRidesTheActivePageAndDocks() async {
        let profile = makeProfile(posts: (1...30).map {
            post("post-\($0)", reactions: Int64($0))
        })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = profile
        window.makeKeyAndVisible()
        profile.beginLoading()
        for _ in 0..<50 where profile.renderedPosts.isEmpty { await Task.yield() }
        window.layoutIfNeeded()

        #expect(profile.debugHeaderConstant == 0, "at rest the header sits at its origin")
        let dock = profile.debugHeaderTravel
        #expect(dock > 0)

        profile.debugScrollActivePage(to: dock / 2)
        #expect(abs(profile.debugHeaderConstant + dock / 2) < 1, "mid-travel the header rides 1:1")

        profile.debugScrollActivePage(to: dock + 400)
        #expect(abs(profile.debugHeaderConstant + dock) < 1, "past the line the header is DOCKED")
        #expect(profile.debugIdentityAlpha == 0, "identity is gone under the bar")
        #expect(profile.debugIsBarDocked, "…and the selector has moved into the bar")

        profile.debugScrollActivePage(to: 0)
        #expect(abs(profile.debugHeaderConstant) < 1, "and it comes all the way back")
        #expect(profile.debugIdentityAlpha == 1)
        #expect(!profile.debugIsBarDocked, "expanded, the selector is back in the header")

        profile.debugScrollActivePage(to: -60)
        #expect(profile.debugHeaderConstant == 60, "overscroll carries the header down, unclamped")
    }

    // MARK: - The hero title and its crossfade

    /// The gallery title's "Name • Kind" shape splits into the hero's two
    /// lines; a separatorless title is all name.
    @Test func heroTitleSplitsNameFromKind() {
        let paris = PlaceProfileViewController.heroTitleComponents(of: "Paris • City Cluster")
        #expect(paris.name == "Paris")
        #expect(paris.kind == "City Cluster")
        let bare = PlaceProfileViewController.heroTitleComponents(of: "France")
        #expect(bare.name == "France")
        #expect(bare.kind == nil)
    }

    /// The name lives on the banner and ONLY there.
    ///
    /// ⚠️ It does not dock, and that is a consequence rather than a taste:
    /// `installLeadingSelector` must overwrite `titleView` with a zero-sized
    /// view (a sized one keeps a central reservation that collapses the
    /// leading group into a `•••` on a narrow bar), so the docked name and
    /// the docked selector cannot both exist. The profile screen made the
    /// same call for the same reason.
    @Test func thePlaceNameLivesOnTheBannerOnly() {
        let profile = makeProfile()
        profile.loadViewIfNeeded()
        #expect(profile.debugHeroName == "Paris")
        #expect(profile.debugHeroKind == "CITY CLUSTER")
        #expect(profile.navigationItem.title == nil,
                "nothing may draw the name at full strength in the bar")
    }

}
