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
/// Likes, two tabs (a Discover grid and an Activity list, both by
/// popularity), and the follow toggle in its header.
@MainActor
struct PlaceProfileTests {
    private func post(
        _ id: String,
        kind: GalleryPost.Kind = .photo,
        reactions: Int64? = nil,
        publishedAtMS: Int64 = 0,
        author: String? = nil,
        thumbnail: String? = nil
    ) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: kind, isRepost: false,
            thumbnailURL: thumbnail.flatMap { URL(string: $0) },
            caption: "", publishedAtMS: publishedAtMS,
            authorName: author,
            reactionCount: reactions
        )
    }

    private func makeProfile(
        following: ClusterGalleryFollowing? = nil,
        wallet: WalletStore? = nil,
        posts: [GalleryPost] = [],
        rank: PlaceRankBadge? = nil
    ) -> PlaceProfileViewController {
        PlaceProfileViewController(
            postIDs: posts.map(\.id),
            placeName: "Paris • City Cluster",
            rank: rank,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: nil,
            following: following,
            wallet: wallet,
            loadPosts: { posts },
            openPost: { _, _, _ in }
        )
    }

    // MARK: - The landing

    /// ⚠️ NO FLIGHT LANDS HERE. A media marker's feed used to fly a photograph's
    /// downward close onto a Discover tile, while a text marker's closed onto
    /// the Activity row — two tabs for one gesture (filmed: Lyon wrong, Paris
    /// right). The refusal is what hands every downward close to the card
    /// close, and the map's driver asks this same answer
    /// (`InteractiveSlideDismissal.heroClaimsAxis`).
    @Test func thePageRefusesAHero() {
        let profile = makeProfile(posts: [post("p1")])
        #expect(profile.zoomLandingAcceptsHero == false)
    }

    // MARK: - The banner

    /// Laid out at a real viewport, so the fraction has something to be a
    /// fraction OF: a headless `loadViewIfNeeded` leaves the view at zero and
    /// every derived number with it.
    private func laidOut(_ profile: PlaceProfileViewController) {
        profile.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        profile.loadViewIfNeeded()
        profile.view.layoutIfNeeded()
        profile.viewDidLayoutSubviews()
    }

    /// A COVER, as a profile's poster: the banner runs down 80% of the
    /// screen (user, 5 October 2026), the identity row at its foot — well
    /// below where the poster's old 200pt stage put it.
    @Test func theCoverRunsDownEightyPercentOfTheScreen() {
        let profile = makeProfile()
        laidOut(profile)
        let screen = profile.view.bounds.height
        #expect(abs(profile.debugBannerHeight - (screen * 0.8).rounded()) < 1,
                "banner \(profile.debugBannerHeight) of \(screen)")
        // The content — the identity row, then the posts — starts at 40%,
        // over the picture's lower part.
        #expect(abs(profile.debugIdentityFrame.minY - (screen * 0.4).rounded()) < 1,
                "identity at \(profile.debugIdentityFrame.minY)")
        #expect(profile.debugHeaderBottom < profile.debugBannerHeight, "the posts wait under the picture")
    }

    /// The HEADER — what the pages are inset by — ends under the identity row
    /// by the clearance, and nowhere else: derived from its content, so
    /// Dynamic Type cannot put type off it. The counters stand inside the
    /// row, above its foot. (The picture runs on below, under the posts.)
    @Test func theHeaderEndsJustUnderTheIdentity() {
        let profile = makeProfile()
        laidOut(profile)
        #expect(abs(profile.debugIdentityClearance - (profile.debugHeaderBottom - profile.debugIdentityFrame.maxY)) < 1)
        #expect(profile.debugMetricsFrame.maxY <= profile.debugIdentityFrame.maxY + 0.5)
    }

    /// On the profile's grid: the flag on the column's leading edge, as an
    /// avatar is; the name and the counters beside it, to the column's end.
    @Test func theIdentityIsLaidOnTheProfilesColumn() {
        let profile = makeProfile()
        laidOut(profile)
        let identity = profile.debugIdentityFrame
        #expect(abs(identity.minX - HeroBannerMetrics.identityInset) < 0.5)
        #expect(abs(identity.maxX - (402 - HeroBannerMetrics.identityInset)) < 0.5)
        let flagRight = identity.minX + PlaceIdentityView.flagSide
        #expect(profile.debugNameFrame.minX > flagRight, "the name runs under the flag")
        #expect(abs(profile.debugMetricsFrame.minX - profile.debugNameFrame.minX) < 0.5)
        #expect(abs(profile.debugMetricsFrame.maxX - (402 - HeroBannerMetrics.identityInset)) < 0.5)
    }

    /// "#3" rides the flag in its bubble when the place has a rank…
    @Test func aRankedPlaceWearsItsRankOnTheFlag() {
        let profile = makeProfile(rank: PlaceRankBadge(position: 3, label: "City Rank"))
        laidOut(profile)
        #expect(profile.debugRank == "#3")
    }

    /// …and a place with none (every place on the fleet today) draws no bubble.
    @Test func anUnrankedPlaceDrawsNoRank() {
        let profile = makeProfile()
        laidOut(profile)
        #expect(profile.debugRank == nil)
    }

    /// The identity row is the unlock sheet's (`PlaceIdentityView`): the flag
    /// and the subtitle the map resolved, the name without its kind, and the
    /// place's Likes and Posts — no flag without a country.
    @Test func theIdentityRowWearsTheFlagAndSubtitleTheMapGave() {
        let flag = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96)).image { _ in }
        let profile = PlaceProfileViewController(
            postIDs: [], placeName: "Paris • City Cluster",
            identity: PlaceIdentity(flag: flag, subtitle: "France"),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: nil, loadPosts: { [] }, openPost: { _, _, _ in }
        )
        laidOut(profile)
        let identity = profile.debugIdentity
        #expect(identity.flagView.image === flag)
        #expect(identity.titleLabel.name == "Paris")
        #expect(identity.titleLabel.subtitle == "France")
        #expect(identity.statViews.map(\.captionLabel.text) == ["Likes", "Posts"])

        let bare = makeProfile()
        laidOut(bare)
        #expect(bare.debugIdentity.flagView.image == nil, "a flag out of nowhere")
        #expect(bare.debugIdentity.titleLabel.subtitle == "")
    }

    /// ⚠️ THE SELECTOR IS ON THE BANNER, NOT UNDER IT — bottoms level.
    ///
    /// And the SLOT is what is pinned there, not the bar: `headerHost` takes
    /// its whole height from `slot.bottom == host.bottom`, so anchoring the BAR
    /// to the picture would make every number derived from the header — the
    /// pages' inset, the dock line, the content floor — hostage to a control
    /// ⚠️ THE HEADER IS NO LONGER THE BANNER (5 October 2026). It was —
    /// the banner's bottom gave the header its height — until the cover and
    /// its content were dissociated: the header ends with the identity row,
    /// the pages are inset by it, and the picture runs on below, BEHIND the
    /// first posts, to 80% of the screen.
    @Test func theBannerRunsOnBehindThePosts() {
        let profile = makeProfile()
        laidOut(profile)
        #expect(profile.debugBannerHeight > profile.debugHeaderBottom + 50,
                "banner \(profile.debugBannerHeight), header \(profile.debugHeaderBottom)")
        #expect(profile.debugIdentityRidesTheBanner)
    }

    /// ⚠️ THE COUNTERS MUST CLEAR THE CAPSULE THAT NOW OVERLAPS THEM. The old
    /// -18 was measured against the picture's edge, and the moment the selector
    /// moved onto the banner that edge stopped being the last thing in the way.
    @Test func theIdentityClearsTheSelectorItNowSharesTheBannerWith() {
        let profile = makeProfile()
        laidOut(profile)
        #expect(profile.debugIdentityClearance >= PagedTabBar.Style.navigationTitle.height)
    }

    /// ⚠️ WHAT COVERS THE LIST IS NOT WHAT THE LIST IS INSET BY. This page
    /// reserves the header's whole height as scrollable RANGE, and most of that
    /// is room the content scrolls into rather than chrome it hides behind. A
    /// landing that took the inset for the cover would think the visible band
    /// was a sliver at the foot of the screen and haul the list about to reach
    /// it.
    @Test func theLandingClearsTheHeaderBandRatherThanTheContentInset() {
        let profile = makeProfile()
        laidOut(profile)
        let occlusion = profile.debugLandingOcclusion
        #expect(occlusion.top >= profile.view.safeAreaInsets.top)
        // ⚠️ AND STRICTLY LESS THAN THE HEADER AT REST. The list scrolls UNDER
        // the header, so the room a landing can reach is what is left once it
        // has docked — not where it is standing at the moment of the ask.
        // Measuring the header instead made the band ~270pt on an 874pt screen,
        // every card "taller than the gap", and the landing moved nothing.
        #expect(occlusion.top < profile.debugHeaderBottom)
        #expect(occlusion.top < profile.view.bounds.height / 4)
    }

    /// The name and the counters are the place's identity, so they sit ON the
    /// picture, one under the other, rather than in a band beneath it.
    @Test func theNameAndCountersRideTheBanner() {
        let profile = makeProfile()
        laidOut(profile)
        #expect(profile.debugIdentityRidesTheBanner)
    }

    /// The picture runs under the whole identity — the name and the counters
    /// — fading into the page from just above the name, whole by the
    /// banner's edge, so the list below starts on the page with no seam.
    @Test func thePictureRunsUnderTheIdentityToTheFoot() throws {
        let profile = makeProfile()
        laidOut(profile)
        let fade = try #require(profile.debugBannerFade)
        let box = profile.debugBannerBoxFrame
        #expect(fade.rampStart < profile.debugNameFrame.minY)
        #expect(abs(fade.rampEnd - box.maxY) < 0.5)
        #expect(profile.debugRampAlphas.last == 1)
    }

    /// The image lags the scroll and is cut taller than its viewport, so the
    /// lag can never expose an edge: at the furthest the header travels, the
    /// image's top is still at or above the box's.
    @Test func theBannerImageLagsTheScrollWithoutExposingAnEdge() {
        let profile = makeProfile()
        laidOut(profile)
        let atRest = profile.debugBannerImageTop
        #expect(atRest < 0, "the image is cut taller than its viewport")

        profile.debugApplyHeaderOffset(2_000)
        let scrolled = profile.debugBannerImageTop
        #expect(scrolled > atRest, "the image did not lag the scroll")
        #expect(scrolled <= 0, "the lag exposed the image's top edge")
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

    /// The hero banner wears the GALLERY's top post — the same post the
    /// cluster pin's face and Discover's first tile show.
    ///
    /// ⚠️ THREE FACES, ONE PICTURE, and it is the reason the banner is asked of
    /// the gallery rather than of the whole corpus. The pin wears its most-liked
    /// MEDIA member; so does the first tile. Handed the full ranking instead, a
    /// place whose loudest post is a check-in would show a neutral banner over
    /// a grid whose first tile is the very photograph the pin is wearing.
    @Test func theBannerWearsTheTopGalleryPost() {
        let posts = [
            post("post-1", reactions: 12, thumbnail: "mock://cover-1"),
            post("post-2", reactions: 480, thumbnail: "mock://cover-2"),
        ]
        #expect(PlaceProfileViewController.bannerPost(
            in: PlaceProfileViewController.gallery(posts))?.id == PostID("post-2"))
        #expect(PlaceProfileViewController.bannerPost(in: []) == nil)

        // The loudest post in the place is words: the banner takes the loudest
        // PICTURE instead, which is what the pin and the first tile are wearing.
        let shouted = posts + [post("post-3", kind: .text, reactions: 9_000)]
        #expect(PlaceProfileViewController.bannerPost(
            in: PlaceProfileViewController.gallery(shouted))?.id == PostID("post-2"))
    }

    /// The band's Likes is a straight sum — client-side, since counter.v1 has
    /// no place entity; a counter the read-model never projected counts as
    /// zero, never poisons the total. (It stood beside a Views total until
    /// 2026-09-30.)
    @Test func likesAggregateOverEveryMember() {
        let likes = PlaceProfileViewController.aggregatedLikes(of: [
            post("post-1", reactions: 100),
            post("post-2", reactions: 40),
            post("post-3", reactions: nil),
        ])
        #expect(likes == 140)
    }

    // MARK: - Activity

    /// The Activity tab is MOST POPULAR first — reactions, then recency, then
    /// id: the page's one ranking, not a second formula — and it carries EVERY
    /// kind: a place's activity is its posts, so words, stills and video all
    /// travel.
    @Test func activityIsMostPopularFirstAndKeepsEveryKind() {
        let ordered = PlaceProfileViewController.activity([
            post("post-1", kind: .photo, reactions: 40, publishedAtMS: 3_000),
            post("post-2", kind: .text, reactions: 900, publishedAtMS: 1_000),
            post("post-3", kind: .video, reactions: 120, publishedAtMS: 2_000),
            // A tie on reactions: the newer one leads.
            post("post-4", kind: .photo, reactions: 40, publishedAtMS: 4_000),
        ])
        #expect(ordered.map(\.id.rawValue) == ["post-2", "post-3", "post-4", "post-1"])
        #expect(Set(ordered.map(\.kind)) == [.photo, .text, .video],
                "no kind is filtered out — the cards show what For You's own card tab does")
        #expect(ordered == PlaceProfileViewController.ranked(ordered),
                "the same ranking Discover leads with, so the two tabs cannot disagree")
    }

    /// Which posts open through a WINDOW rather than the platform's slide.
    ///
    /// ⚠️ Both errors here are silent, which is why the rule is pinned apart
    /// from the animation. A text row denied its window keeps the plain push —
    /// a perfectly good slide, and precisely how this screen shipped without
    /// one while every other list had it. A media row handed one would open a
    /// card onto a photograph the card does not draw.
    @Test func onlyTextRowsOnTheListTabOpenThroughAWindow() {
        #expect(PlaceProfileViewController.textWindowIsAvailable(
            for: post("post-1", kind: .text), onListTab: true))
        #expect(!PlaceProfileViewController.textWindowIsAvailable(
            for: post("post-2", kind: .photo), onListTab: true))
        #expect(!PlaceProfileViewController.textWindowIsAvailable(
            for: post("post-3", kind: .video), onListTab: true))
        // Discover is a GRID: its text posts are tiles, with no caption to
        // open out of and nothing for the window to be shaped like.
        #expect(!PlaceProfileViewController.textWindowIsAvailable(
            for: post("post-4", kind: .text), onListTab: false))
    }

    /// The whole fan-out through one hydration: both tabs populated from one
    /// corpus under one ranking — popularity — and differing only in what a
    /// grid can draw.
    ///
    /// ⚠️ THEY NO LONGER SHOW THE SAME POSTS. Discover is a GRID of covers and
    /// drops what has none; Activity is a column of cards and keeps every kind.
    /// The place's own numbers still come from the whole corpus — see
    /// `theMetricsCountTheWholePlaceNotJustItsGallery`.
    @Test func oneHydrationFansOutToBothTabs() async {
        let profile = makeProfile(posts: [
            post("post-1", kind: .photo, reactions: 50, publishedAtMS: 1_000),
            post("post-2", kind: .video, reactions: 90, publishedAtMS: 2_000),
            // The loudest post, and the OLDEST: first by popularity, last by date.
            post("post-3", kind: .text, reactions: 900, publishedAtMS: 500),
        ])
        profile.beginLoading()
        for _ in 0..<50 where profile.renderedPosts.isEmpty { await Task.yield() }
        #expect(profile.renderedPosts.map(\.id.rawValue) == ["post-2", "post-1"],
                "a text post has no cover and cannot be a tile")
        #expect(profile.renderedActivity.map(\.id.rawValue) == ["post-3", "post-2", "post-1"],
                "the cards keep every kind — its words are not lost, only moved")
        #expect(profile.tabTitles == ["Activity", "Discover"],
                "Activity on the left, Discover on the right")
    }

    /// ⚠️ A DISMISSAL FROM THE MAP LANDS ON ACTIVITY, WITH THE POST THE VIEWER
    /// WAS ON AT ITS HEAD — whatever that post's kind, and whatever tab the
    /// page was on.
    ///
    /// It used to depend on the route: a media marker's feed closed onto the
    /// first DISCOVER tile, a text marker's onto the Activity row. Pinned here
    /// through the landing's one entry point (`cardCloseGeometry`, which both
    /// routes now reach), for a photograph, a clip and words.
    @Test(arguments: [GalleryPost.Kind.photo, .video, .text])
    func aDismissalFromTheMapLandsOnActivityWithThePostFirst(kind: GalleryPost.Kind) async {
        let profile = makeProfile(posts: [
            post("post-1", kind: .photo, reactions: 50),
            post("post-2", kind: .photo, reactions: 90),
            post("post-3", kind: kind, reactions: 10),
        ])
        laidOut(profile)
        profile.beginLoading()
        for _ in 0..<50 where profile.renderedActivity.isEmpty { await Task.yield() }
        #expect(profile.renderedActivity.first?.id == PostID("post-2"),
                "precondition: the ranking put post-2 first")

        // The viewer paged on to the least popular post before closing.
        profile.activePostID = { PostID("post-3") }
        let feed = UIViewController()
        feed.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        _ = profile.cardCloseGeometry(dismissing: feed)
        #expect(profile.debugActiveTabTitle == "Activity",
                "the landing chose a tab by the post's kind again")
        #expect(profile.debugLandingAnchor == PostID("post-3"))
        #expect(profile.renderedActivity.first?.id == PostID("post-3"),
                "the post the viewer was on is not at the head of the list")
        #expect(Set(profile.renderedActivity.map(\.id)).count == 3, "no second copy")

        // Asked again — a swipe asks twice — it stays put rather than swapping back.
        _ = profile.cardCloseGeometry(dismissing: feed)
        #expect(profile.renderedActivity.first?.id == PostID("post-3"))
    }

    /// ⚠️ EVERY POSITION IS ASKED OF THE ORDER, and the landing proves it: with
    /// Activity moved to the LEFT, a staging that still spoke in the old `1`
    /// would put the strip on Discover's slot while revealing an Activity row.
    /// Driven from Discover so the landing has a tab to move off.
    @Test func theActivityLandingFollowsTheTabOrder() async {
        let profile = makeProfile(posts: [
            post("post-1", kind: .photo, reactions: 50),
            post("post-2", kind: .photo, reactions: 90),
        ])
        laidOut(profile)
        profile.beginLoading()
        for _ in 0..<50 where profile.renderedActivity.isEmpty { await Task.yield() }
        #expect(PlaceProfileViewController.tabOrder == [.activity, .discover])
        #expect(profile.debugActiveTabTitle == "Activity", "the page rests on its first tab")

        profile.debugSelectTab(.discover)
        #expect(profile.debugActiveTabTitle == "Discover")

        profile.activePostID = { PostID("post-1") }
        let feed = UIViewController()
        feed.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        _ = profile.cardCloseGeometry(dismissing: feed)
        #expect(profile.debugActiveTabTitle == "Activity")
        #expect(profile.debugSelectedTabTitle == "Activity",
                "the strip's pill sits on another tab than the page the close landed on")
    }

    /// `-maps-place-tab` takes a NAME, which survives a reorder, or a position.
    @Test func thePlaceTabArgumentTakesANameOrAPosition() {
        #expect(PlaceProfileViewController.debugTabIndex("activity") == 0)
        #expect(PlaceProfileViewController.debugTabIndex("Discover") == 1)
        #expect(PlaceProfileViewController.debugTabIndex("1") == 1)
        #expect(PlaceProfileViewController.debugTabIndex("2") == nil)
        #expect(PlaceProfileViewController.debugTabIndex("shorts") == nil)
    }

    /// The gallery's rule, on its own: the ranking minus what a grid cannot
    /// draw, in that order.
    @Test func theGalleryIsTheRankingMinusWhatHasNoCover() {
        let ordered = PlaceProfileViewController.gallery([
            post("post-1", kind: .photo, reactions: 50),
            post("post-2", kind: .text, reactions: 900),
            post("post-3", kind: .video, reactions: 90),
        ])
        #expect(ordered.map(\.id.rawValue) == ["post-3", "post-1"],
                "the loudest post in the place is words, and words are not a tile")
    }

    /// ⚠️ AND THE NUMBERS ARE NOT THE GALLERY'S. A check-in with no photograph
    /// is still something that happened here; dropping it from a total because
    /// a grid cannot draw it would make the place look quieter than it is.
    @Test func theMetricsCountTheWholePlaceNotJustItsGallery() async {
        let profile = makeProfile(posts: [
            post("post-1", kind: .photo, reactions: 50, publishedAtMS: 1_000),
            post("post-2", kind: .text, reactions: 7, publishedAtMS: 2_000),
        ])
        profile.beginLoading()
        for _ in 0..<50 where profile.renderedPosts.isEmpty { await Task.yield() }
        #expect(profile.renderedPosts.count == 1, "precondition: the text post left the grid")
        #expect(profile.debugLikes == 57)
        // Both posts count, the text one too.
        #expect(profile.debugIdentity.statViews.map(\.valueLabel.text) == ["57", "2"])
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

        // The pin alone carries the state — no word rides beside it, so the
        // FILL is what a test reads and what a viewer sees.
        let item = try #require(profile.navigationItem.rightBarButtonItems?.first)
        #expect(item.title == nil, "a titled item would be charged its word against the bar")
        #expect(item.image == UIImage(systemName: "pin"))
        #expect(item.accessibilityLabel == "Follow this place")

        let action = try #require(item.primaryAction)
        action.performWithSender(nil, target: nil)
        #expect(followed, "the toggle reached the caller's store")
        #expect(item.image == UIImage(systemName: "pin.fill"))
        #expect(item.accessibilityLabel == "Unfollow this place")

        action.performWithSender(nil, target: nil)
        #expect(!followed)
        #expect(item.image == UIImage(systemName: "pin"))
    }

    /// Each trailing item earns its place from a seam: no follow closure, no
    /// pin; no wallet, no balance. An inert control would promise a feature
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
    /// is the RIGHTMOST item, so the pin keeps the corner it has always had
    /// and the balance sits inboard of it — the order the map already puts
    /// its coin inboard of the bell.
    @Test func thePointsBalanceSitsInboardOfThePin() throws {
        let profile = makeProfile(
            following: ClusterGalleryFollowing(isFollowing: { false }, toggle: { true }),
            wallet: WalletStore(defaults: Self.makeWalletDefaults())
        )
        profile.loadViewIfNeeded()
        let items = try #require(profile.navigationItem.rightBarButtonItems)
        #expect(items.count == 2)
        #expect(items[0].image == UIImage(systemName: "pin"), "the corner is the pin's")
        #expect(items[1].customView is WalletBadgeButton)
        #expect(items[1].accessibilityLabel == "Points balance")
        // ⚠️ Each in its OWN bubble. Sharing the group's one platter is what
        // makes two controls read as a segmented pair — the map's coin and
        // bell, the profile's tray and For You's all opt out the same way.
        #expect(items.allSatisfy { !$0.sharesBackground })
    }

    /// ⚠️ THE HAND-OVER TEST IS GONE BECAUSE THE HAND-OVER IS. There were two
    /// selector copies crossfading at a dock line — an inline one in the
    /// header's slot and a docked one in the navigation bar's leading group —
    /// and four tests drove `debugIsBarDocked` through it. The strip lives at
    /// the foot of the screen now and never moves, so there is no threshold, no
    /// crossfade and no bar item to be present or absent.

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

        profile.debugScrollActivePage(to: 0)
        #expect(abs(profile.debugHeaderConstant) < 1, "and it comes all the way back")
        #expect(profile.debugIdentityAlpha == 1)

        profile.debugScrollActivePage(to: -60)
        #expect(profile.debugHeaderConstant == 60, "overscroll carries the header down, unclamped")
    }

    // MARK: - The hero title and its crossfade

    /// The gallery title's "Name • Kind" shape splits; a separatorless title is
    /// all name.
    ///
    /// ⚠️ THE SPLITTER OUTLIVED THE LINE IT FED. The hero no longer draws the
    /// kind at all, but `placeName` still arrives as `MapPlace.galleryTitle` —
    /// "Paris • City Cluster" — so this is the only thing that yields "Paris".
    /// Delete it and the banner draws the separator and the exact words the
    /// kind line was removed for.
    @Test func heroTitleSplitsNameFromKind() {
        let paris = PlaceProfileViewController.heroTitleComponents(of: "Paris • City Cluster")
        #expect(paris.name == "Paris")
        #expect(paris.kind == "City Cluster")
        let bare = PlaceProfileViewController.heroTitleComponents(of: "France")
        #expect(bare.name == "France")
        #expect(bare.kind == nil)
    }

    /// The name lives on the banner and ONLY there — and it is the whole of
    /// the hero: the "CITY CLUSTER" line above it was deleted, because the map
    /// the viewer just came from had already said which kind of cluster this
    /// is, and repeating it was a taxonomy label competing with an identity.
    ///
    /// ⚠️ It does not dock, and that is a consequence rather than a taste:
    /// a leading selector had to overwrite `titleView` with a zero-sized
    /// view (a sized one keeps a central reservation that collapses the
    /// leading group into a `•••` on a narrow bar), so the docked name and
    /// the docked selector cannot both exist. The profile screen made the
    /// same call for the same reason.
    @Test func thePlaceNameLivesOnTheBannerOnly() {
        let profile = makeProfile()
        profile.loadViewIfNeeded()
        #expect(profile.debugHeroName == "Paris")
        #expect(profile.navigationItem.title == nil,
                "nothing may draw the name at full strength in the bar")
    }


    // MARK: - Pull to refresh

    /// A place whose answers a test hands out one at a time: each hydration
    /// takes the next, and `held` keeps one in flight until it is let go.
    @MainActor
    private final class Answers {
        struct Failure: Error {}
        var queue: [Result<[GalleryPost], Failure>]
        var held = false
        private(set) var calls = 0

        init(_ queue: [Result<[GalleryPost], Failure>]) { self.queue = queue }

        func next() async throws -> [GalleryPost] {
            calls += 1
            while held { try? await Task.sleep(for: .milliseconds(2)) }
            let answer = queue.count > 1 ? queue.removeFirst() : queue[0]
            return try answer.get()
        }
    }

    private func makeProfile(answers: Answers) -> PlaceProfileViewController {
        PlaceProfileViewController(
            postIDs: [PostID("p1")],
            placeName: "Paris • City Cluster",
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: nil,
            loadPosts: { try await answers.next() },
            openPost: { _, _, _ in }
        )
    }

    /// Waits for `condition`, for at most two seconds — long enough for any
    /// hydration here, short enough that a spinner that never stops fails
    /// the test instead of hanging it.
    private func settle(until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// The first hydration, landed.
    private func hydrated(_ answers: Answers) async -> PlaceProfileViewController {
        let profile = makeProfile(answers: answers)
        profile.beginLoading()
        await settle(until: { !profile.renderedActivity.isEmpty })
        return profile
    }

    enum RefreshOutcome: CaseIterable, Sendable { case sameMembers, newMembers, failure }

    /// ⚠️ A PULL ALWAYS ENDS ITS SPINNER — on either tab, whatever the
    /// refresh brought back.
    ///
    /// Both pages carried a `UIRefreshControl` and nothing answered it: a
    /// release through the control started a spinner that never stopped. The
    /// identical answer is the case a render-driven stop would miss (it
    /// publishes nothing), and the failure the case an error path would.
    @Test(arguments: RefreshOutcome.allCases, [PlaceProfileViewController.Tab.activity, .discover])
    func aPullAlwaysEndsItsSpinner(outcome: RefreshOutcome, tab: PlaceProfileViewController.Tab) async {
        let first = [post("p1", reactions: 10), post("p2", reactions: 5)]
        let refreshed: Result<[GalleryPost], Answers.Failure> = switch outcome {
        case .sameMembers: .success(first)
        case .newMembers: .success(first + [post("p3", reactions: 50)])
        case .failure: .failure(Answers.Failure())
        }
        let answers = Answers([.success(first), refreshed])
        let profile = await hydrated(answers)

        profile.debugReleasePull(on: tab)
        #expect(profile.debugIsRefreshing, "the release did not start the spinner")
        await settle(until: { !profile.debugIsRefreshing })

        #expect(!profile.debugIsRefreshing, "the spinner never stopped")
        #expect(answers.calls == 2, "the pull must load the place again")
    }

    /// The pull is the profile's: the pages carry no stock control (it sat
    /// under the banner, and a real drag never tripped it), and a release
    /// short of the indicator's threshold refreshes nothing.
    @Test func thePullIsTheIndicatorsNotAStockControl() async {
        let answers = Answers([.success([post("p1", reactions: 10)])])
        let profile = await hydrated(answers)
        #expect(!profile.debugPagesCarryRefreshControl)

        profile.debugReleasePull(on: .activity, by: HeroPullToRefreshView.threshold - 20)
        await settle(until: { answers.calls > 1 })

        #expect(answers.calls == 1, "a pull short of the threshold refreshed")
        #expect(!profile.debugIsRefreshing)
    }

    /// The same members again is no news: nothing reaches the page.
    @Test func aRefreshThatBringsNothingNewPublishesNothing() async {
        let answers = Answers([.success([post("p1", reactions: 10), post("p2", reactions: 5)])])
        let profile = await hydrated(answers)
        #expect(profile.debugRenderCount == 1)

        profile.debugReleasePull(on: .activity)
        await settle(until: { !profile.debugIsRefreshing })

        #expect(profile.debugRenderCount == 1, "an identical answer re-rendered the page")
        #expect(profile.renderedActivity.map(\.id.rawValue) == ["p1", "p2"])
    }

    /// New members land in place, through the same fan-out as the first
    /// hydration: both tabs and the place's numbers.
    @Test func aRefreshThatBringsNewPostsLandsThemInPlace() async {
        let answers = Answers([
            .success([post("p1", reactions: 10)]),
            .success([post("p1", reactions: 10), post("p2", reactions: 90)]),
        ])
        let profile = await hydrated(answers)

        profile.debugReleasePull(on: .discover)
        await settle(until: { !profile.debugIsRefreshing })

        #expect(profile.renderedActivity.map(\.id.rawValue) == ["p2", "p1"])
        #expect(profile.renderedPosts.map(\.id.rawValue) == ["p2", "p1"])
        #expect(profile.debugLikes == 100)
    }

    /// A failed revalidation leaves the place it already showed.
    @Test func aFailedRefreshKeepsWhatIsOnScreen() async {
        let answers = Answers([.success([post("p1", reactions: 10)]), .failure(Answers.Failure())])
        let profile = await hydrated(answers)

        profile.debugReleasePull(on: .activity)
        await settle(until: { !profile.debugIsRefreshing })

        #expect(profile.renderedActivity.map(\.id.rawValue) == ["p1"])
    }

    /// A pull during the first hydration starts nothing of its own — and the
    /// hydration's settle still ends its spinner.
    @Test func aPullDuringTheFirstHydrationEndsWithIt() async {
        let answers = Answers([.success([post("p1", reactions: 10)])])
        answers.held = true
        let profile = makeProfile(answers: answers)
        profile.beginLoading()
        await settle(until: { answers.calls == 1 })

        profile.debugReleasePull(on: .activity)
        #expect(profile.debugIsRefreshing)
        answers.held = false
        await settle(until: { !profile.debugIsRefreshing })

        #expect(!profile.debugIsRefreshing, "the coalesced pull's spinner never stopped")
        #expect(answers.calls == 1, "a pull in flight must not start a second load")
        #expect(profile.renderedActivity.map(\.id.rawValue) == ["p1"])
    }

    /// The failed page's "Try Again" (and a pull on it) loads the place
    /// again — it used to be a button that did nothing.
    @Test func aRetryAfterAFailedHydrationLoadsThePlace() async {
        let answers = Answers([.failure(Answers.Failure()), .success([post("p1", reactions: 10)])])
        let profile = makeProfile(answers: answers)
        profile.beginLoading()
        await settle(until: { answers.calls == 1 && !profile.debugIsLoading })
        #expect(profile.renderedActivity.isEmpty)

        profile.debugReleasePull(on: .activity)
        await settle(until: { !profile.renderedActivity.isEmpty && !profile.debugIsRefreshing })

        #expect(profile.renderedActivity.map(\.id.rawValue) == ["p1"])
        #expect(!profile.debugIsRefreshing)
    }
}
