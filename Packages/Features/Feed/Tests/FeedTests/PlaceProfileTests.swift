import CoreModels
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
        posts: [GalleryPost] = []
    ) -> PlaceProfileViewController {
        PlaceProfileViewController(
            postIDs: posts.map(\.id),
            placeName: "Paris • City Cluster",
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: nil,
            following: following,
            loadPosts: { posts },
            openPost: { _, _, _ in }
        )
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

    // MARK: - Shorts

    /// The Shorts tab is the place's VIDEOS, ranking preserved — never a
    /// re-sort, never a still.
    @Test func shortsKeepOnlyVideosInRankedOrder() {
        let ranked = PlaceProfileViewController.ranked([
            post("post-1", kind: .photo, reactions: 900),
            post("post-2", kind: .video, reactions: 300),
            post("post-3", kind: .text, reactions: 200),
            post("post-4", kind: .video, reactions: 700),
        ])
        let shorts = PlaceProfileViewController.shorts(in: ranked)
        #expect(shorts.map(\.id.rawValue) == ["post-4", "post-2"])
    }

    // MARK: - Activity

    /// The Activity stream is CHRONOLOGICAL, newest first — the one surface
    /// of the page that is not popularity — and each post's kind decides the
    /// event's verb: words check in, stills are shared, videos are posted.
    @Test func activityIsNewestFirstWithKindVerbs() {
        let events = PlaceProfileViewController.activity(from: [
            post("post-1", kind: .photo, publishedAtMS: 1_000, author: "Ava"),
            post("post-2", kind: .text, publishedAtMS: 3_000, author: "Kenji"),
            post("post-3", kind: .video, publishedAtMS: 2_000),
        ])
        #expect(events.map(\.id.rawValue) == ["post-2", "post-3", "post-1"])
        #expect(events[0].kind == .checkIn)
        #expect(events[0].authorName == "Kenji")
        #expect(events[1].kind == .short)
        #expect(events[1].authorName == "Someone", "a nameless author still makes a sentence")
        #expect(events[2].kind == .photo)
        #expect(PlaceActivityEvent.Kind.checkIn.verb == "checked in")
        #expect(PlaceActivityEvent.Kind.photo.verb == "shared a photo")
        #expect(PlaceActivityEvent.Kind.short.verb == "posted a short")
    }

    /// The whole fan-out through one hydration: gallery, shorts and activity
    /// all populated from one corpus, each under its own rule.
    @Test func oneHydrationFansOutToAllThreeTabs() async {
        let profile = makeProfile(posts: [
            post("post-1", kind: .photo, reactions: 50, publishedAtMS: 1_000),
            post("post-2", kind: .video, reactions: 90, publishedAtMS: 2_000),
            post("post-3", kind: .text, reactions: 10, publishedAtMS: 3_000),
        ])
        profile.beginLoading()
        for _ in 0..<50 where profile.renderedPosts.isEmpty { await Task.yield() }
        #expect(profile.renderedPosts.map(\.id.rawValue) == ["post-2", "post-1", "post-3"])
        #expect(profile.renderedShorts.map(\.id.rawValue) == ["post-2"])
        #expect(profile.renderedActivity.map(\.id.rawValue) == ["post-3", "post-2", "post-1"])
        #expect(profile.tabTitles == ["Gallery", "Shorts", "Activity"])
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

        let button = try #require(profile.navigationItem.rightBarButtonItem?.customView as? UIButton)
        func label() -> String? {
            button.configuration?.attributedTitle.map { String($0.characters) }
        }
        #expect(label() == "Follow")

        button.sendActions(for: .primaryActionTriggered)
        #expect(followed, "the toggle reached the caller's store")
        #expect(label() == "Following")

        button.sendActions(for: .primaryActionTriggered)
        #expect(!followed)
        #expect(label() == "Follow")
    }

    /// A profile whose subject has no followable identity shows no button at
    /// all — an inert heart would promise a feature the caller can't honor.
    @Test func withoutAFollowSeamTheHeaderStaysBare() {
        let profile = makeProfile(following: nil)
        profile.loadViewIfNeeded()
        #expect(profile.navigationItem.rightBarButtonItem == nil)
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
        #expect(profile.debugNavTitleAlpha == 1, "…and the name has moved into the bar")

        profile.debugScrollActivePage(to: 0)
        #expect(abs(profile.debugHeaderConstant) < 1, "and it comes all the way back")
        #expect(profile.debugIdentityAlpha == 1)
        #expect(profile.debugNavTitleAlpha == 0, "expanded, the bar's title slot is empty again")

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

    /// The name lives on the banner while expanded and in the bar while
    /// docked — one string, two homes, complementary alphas — and the
    /// navigation item's own `title` stays empty so nothing draws it at
    /// full strength over either.
    @Test func thePlaceNameCrossfadesBetweenBannerAndBar() {
        let profile = makeProfile()
        profile.loadViewIfNeeded()
        #expect(profile.debugHeroName == "Paris")
        #expect(profile.debugHeroKind == "CITY CLUSTER")
        #expect(profile.debugNavTitleText == "Paris • City Cluster")
        #expect(profile.debugNavTitleAlpha == 0, "expanded: the bar slot starts empty")
        #expect(profile.navigationItem.title == nil)
        #expect(profile.navigationItem.titleView != nil)
    }

    // MARK: - Relative age

    @Test func relativeAgeSpeaksTheFeedsShortVocabulary() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func age(secondsAgo: TimeInterval) -> String {
            PlaceActivityListView.relativeAge(
                ofMS: Int64((now.timeIntervalSince1970 - secondsAgo) * 1000), now: now
            )
        }
        #expect(age(secondsAgo: 30) == "1m", "sub-minute rounds up — nothing reads 0m")
        #expect(age(secondsAgo: 300) == "5m")
        #expect(age(secondsAgo: 7_200) == "2h")
        #expect(age(secondsAgo: 200_000) == "2d")
        #expect(age(secondsAgo: 1_300_000) == "2w")
    }
}
