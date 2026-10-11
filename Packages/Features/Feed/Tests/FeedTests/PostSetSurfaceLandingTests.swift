import CoreModels
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// Where a close from the search results' post grid lands (#883).
///
/// The surface is a CHILD of the search results screen (a page of its pager),
/// pushed over by the post it opens. A close puts that screen back under the
/// flight's depth recede — the grid scaled to 0.95 about its centre — while
/// the pop brings the screen's chrome back. An unpinned grid then re-resolved
/// its safe area from its SCALED frame (2.5% of its height in from each
/// edge), its inset and offset followed, and every tile slid 22pt up under
/// the card: the card came down above the tile, and the tile dropped into
/// place once the screen was back. For You's own grid is pinned by its flight
/// source as the close stages; these pin the search grid the same way.
@MainActor
struct PostSetSurfaceLandingTests {
    /// `ZoomFlight.presenterDepthScale`, internal to CoreNavigation.
    private static let depthScale: CGFloat = 0.95

    /// The search results' arrangement: a navigation stack whose top is a
    /// screen hosting the surface as a child, in a phone-sized window.
    @MainActor
    private final class Stage {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let navigation: UINavigationController
        let screen = UIViewController()
        let surface: PostSetSurfaceViewController

        /// Eight photographs by default. `posts` and `lead` stage the hashtag
        /// page instead (#924): its list, and its Recent row over it.
        init(
            style: PostSetSurfaceStyle = .discover,
            posts: [GalleryPost] = (1...8).map { Stage.post("p\($0)", kind: .photo) },
            lead: [GalleryPost] = []
        ) {
            let ids = posts.map(\.id)
            let byID = Dictionary((posts + lead).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            surface = PostSetSurfaceViewController(
                style: style,
                imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
                videoPlayback: nil,
                hydrate: { ids in ids.compactMap { byID[$0] } }
            )
            screen.addChild(surface)
            surface.view.frame = screen.view.bounds
            surface.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            screen.view.addSubview(surface.view)
            surface.didMove(toParent: screen)
            navigation = UINavigationController(rootViewController: UIViewController())
            navigation.pushViewController(screen, animated: false)
            window.rootViewController = navigation
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            surface.show(.posts(ids))
            if !lead.isEmpty { surface.showLeadRow(.posts(lead.map(\.id))) }
        }

        static func post(_ id: String, kind: GalleryPost.Kind) -> GalleryPost {
            GalleryPost(
                id: PostID(id), kind: kind, isRepost: false,
                thumbnailURL: nil,
                caption: kind == .text ? "Sunday market haul, the words of \(id) #foodie" : id,
                publishedAtMS: 0,
                authorID: kind == .text ? ProfileID("a-\(id)") : nil,
                authorName: kind == .text ? "Nina Varga" : nil,
                authorHandle: kind == .text ? "nina.varga" : nil,
                reactionCount: nil
            )
        }

        /// The grab's landing read (`ZoomDismissInteractionController
        /// .currentLanding`): the depth view momentarily at identity, which is
        /// the space the card's own frame lives in.
        func landing(_ origin: SnapFeedHeroOrigin) -> CGRect? {
            let depth = origin.depthView()
            let recede = depth?.transform ?? .identity
            depth?.transform = .identity
            defer { depth?.transform = recede }
            return origin.frame(window)
        }
    }

    private func settleUntil(_ condition: () -> Bool) async {
        for _ in 0..<2_000 {
            await Task.yield()
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Opens item `index` through the page's selection path, the one a finger
    /// reaches. `push` decides whether the opener covers the screen with a
    /// stand-in feed, as the real one does, or refuses.
    private func open(
        _ index: Int, on stage: Stage, push: Bool
    ) async -> (origin: SnapFeedHeroOrigin, rest: CGRect)? {
        await open(on: stage, push: push) { $0.debugOpenTile(at: index) }
    }

    /// `tap` is the finger: a list item, or a card of the lead row.
    private func open(
        on stage: Stage, push: Bool, tap: (PostSetSurfaceViewController) -> Bool
    ) async -> (origin: SnapFeedHeroOrigin, rest: CGRect)? {
        var opened: (SnapFeedHeroOrigin, CGRect)?
        stage.surface.openPost = { _, origin, _ in
            opened = (origin, origin.frame(stage.window) ?? .null)
            if push { stage.navigation.pushViewController(UIViewController(), animated: false) }
        }
        await settleUntil {
            stage.window.layoutIfNeeded()
            return tap(stage.surface) && opened != nil
        }
        stage.window.layoutIfNeeded()
        return opened
    }

    @Test("A close from the search grid lands on the tile it left, through the depth recede")
    func theLandingIsTheTile() async throws {
        let stage = Stage()
        // No push: the inset is not held from the tap, so only the close's
        // own staging stands between the grid and the drift.
        let opened = try #require(await open(1, on: stage, push: false))
        #expect(!opened.rest.isNull && opened.rest.minY > 0, "no tile to land on")
        #expect(stage.screen.view.safeAreaInsets.top > 30, "no top inset to lose")

        // The flight's close: the source stages, the depth view recedes, and
        // the pop brings the screen's bottom chrome back (the search results'
        // band: 34 → 76), which re-resolves the scaled grid's safe area.
        opened.origin.willStageDismissal()
        opened.origin.depthView()?.transform = CGAffineTransform(
            scaleX: Self.depthScale, y: Self.depthScale
        )
        stage.screen.additionalSafeAreaInsets.bottom = 42
        stage.window.layoutIfNeeded()

        let landing = try #require(stage.landing(opened.origin))
        #expect(abs(landing.minY - opened.rest.minY) <= 1,
                "landed \(landing.minY - opened.rest.minY)pt off the tile")
        #expect(abs(landing.minX - opened.rest.minX) <= 1)
        #expect(abs(landing.size.height - opened.rest.size.height) <= 1)
    }

    @Test("The grid holds still under the post from the tap until the screen is back")
    func theGridIsPinnedForTheVisit() async throws {
        let stage = Stage()
        let opened = try #require(await open(1, on: stage, push: true))
        #expect(stage.surface.debugIsGridInsetPinned, "a covered grid tracking the safe area")

        stage.navigation.popViewController(animated: false)
        stage.window.layoutIfNeeded()
        #expect(!stage.surface.debugIsGridInsetPinned, "the inset never came back")
        let back = try #require(opened.origin.frame(stage.window))
        #expect(abs(back.minY - opened.rest.minY) <= 1, "the tile moved \(back.minY - opened.rest.minY)pt")
    }

    // MARK: - The hashtag page (#924)

    /// ⚠️ THE DROP AT THE END OF A CLOSE (#924, cause b). The hashtag page's
    /// Recent row is this surface's lead row, and its cards opened through
    /// For You's card origin alone, which hands the list's inset back as the
    /// card lands. A grab lands while the screen is still under the depth
    /// recede, so the inset re-resolved against the scaled frame (measured
    /// t116 → t94.1), and once the screen was back at full size the offset
    /// carried the difference: the whole page dropped 22pt and stayed there.
    /// A picture card's flight and a words card's window alike. The list is
    /// pinned from the tap now, and handed back only when the screen is back.
    @Test("A Recent card holds the list still from the tap, through its landing, until the screen is back",
          arguments: [GalleryPost.Kind.video, .text])
    func aLeadCardHoldsTheListStill(kind: GalleryPost.Kind) async throws {
        let lead = [Stage.post("r0", kind: kind), Stage.post("r1", kind: .photo)]
        let stage = Stage(posts: (1...6).map { Stage.post("t\($0)", kind: .text) }, lead: lead)
        let opened = try #require(await open(on: stage, push: true) { $0.debugOpenLeadCard(at: 0) })
        #expect(opened.origin.post.id == lead[0].id)
        #expect(!opened.rest.isNull && opened.rest.minY > 0, "no card to land on")
        #expect(stage.surface.debugIsGridInsetPinned, "a covered list tracking the safe area")

        // The grab: the close stages, the screen recedes about its centre.
        let window = try #require(opened.origin.textReveal)
        if kind == .text { window.willStageDismissal(nil) } else { opened.origin.willStageDismissal() }
        let depth = opened.origin.depthView()
        depth?.transform = CGAffineTransform(scaleX: Self.depthScale, y: Self.depthScale)
        stage.window.layoutIfNeeded()
        let landing = try #require(stage.landing(opened.origin))
        #expect(abs(landing.minY - opened.rest.minY) <= 1, "landed \(landing.minY - opened.rest.minY)pt off the card")
        #expect(abs(landing.minX - opened.rest.minX) <= 1)

        // The landing, STILL RECEDED — a grab reveals its source before it
        // resets the depth: the card shown again, the window's close over.
        if kind == .text { window.dismissalDidEnd(true) } else { opened.origin.setConcealed(false) }
        stage.screen.view.setNeedsLayout()
        stage.window.layoutIfNeeded()
        #expect(stage.surface.debugIsGridInsetPinned, "the landing thawed the list under the recede")

        // The recede reset, the screen back.
        depth?.transform = .identity
        stage.navigation.popViewController(animated: false)
        stage.window.layoutIfNeeded()
        #expect(!stage.surface.debugIsGridInsetPinned, "the inset never came back")
        let back = try #require(opened.origin.frame(stage.window))
        #expect(abs(back.minY - opened.rest.minY) <= 1, "the page dropped \(back.minY - opened.rest.minY)pt")
    }

    /// ⚠️ NO HERO FOR WORDS (#924, cause a). A text post on the hashtag page
    /// or its Recent list has no picture to fly, and this surface handed the
    /// flight no window either — so the builder fell to the stack's plain
    /// slide. It opens out of its card now and closes back onto it, the way
    /// For You's list and the profile open the same card.
    @Test("A text post opens out of its card and closes back onto it",
          arguments: [PostSetSurfaceStyle.discover, .cards])
    func aTextPostOpensAsAWindow(style: PostSetSurfaceStyle) async throws {
        let posts = [Stage.post("t1", kind: .text), Stage.post("m2", kind: .photo), Stage.post("t3", kind: .text)]
        let stage = Stage(style: style, posts: posts)
        let opened = try #require(await open(0, on: stage, push: true))
        #expect(opened.origin.post.id == posts[0].id)
        #expect(!opened.origin.hasHero, "a text post has no picture to fly")
        let window = try #require(opened.origin.textReveal, "a text post opened with the stack's plain slide")
        #expect(window.alignsPageToSource, "the page does not grow out of the card's caption")
        #expect(window.pageFit == .covering)
        #expect(window.captionTop > 0, "no author band to align below")
        #expect(window.authorBand != nil, "the card's header is not borrowed for the flight")
        let row = try #require(window.rowFrame(stage.window))
        #expect(row.minY > stage.screen.view.safeAreaInsets.top - 1 && row.width > 300, "\(row) is not the card")
        let standIn = try #require(window.makeDismissStandIn(nil))
        #expect(standIn is RevealDismissCardView, "the close carries \(type(of: standIn)) home")
        #expect(FeedFeatureBuilder.cardCloseLanding(
            for: stage.surface, origin: opened.origin, pipeline: nil, dock: { $0 }
        ) is RowCardCloseLanding, "no card close beside the window")

        // The window's close stages on a pinned list and leaves the thaw to
        // the screen's appearance.
        window.willStageDismissal(nil)
        #expect(stage.surface.debugIsGridInsetPinned)
        window.dismissalDidEnd(true)
        #expect(stage.surface.debugIsGridInsetPinned, "thawed before the pop settled the chrome")
        stage.navigation.popViewController(animated: false)
        stage.window.layoutIfNeeded()
        #expect(!stage.surface.debugIsGridInsetPinned)
        let back = try #require(window.rowFrame(stage.window))
        #expect(abs(back.minY - row.minY) <= 1, "the card moved \(back.minY - row.minY)pt")
    }

    /// A MEDIA post keeps its flight, and carries the window too: paged onto
    /// words, the close has a card to land through rather than a cut.
    @Test("A media post keeps its flight and carries a window for a close from words",
          arguments: [PostSetSurfaceStyle.discover, .cards])
    func aMediaPostCarriesAWindow(style: PostSetSurfaceStyle) async throws {
        let posts = [Stage.post("t1", kind: .text), Stage.post("m2", kind: .photo), Stage.post("t3", kind: .text)]
        let stage = Stage(style: style, posts: posts)
        let opened = try #require(await open(1, on: stage, push: true))
        #expect(opened.origin.post.id == posts[1].id)
        #expect(opened.origin.hasHero, "a picture no longer flies")
        let window = try #require(opened.origin.textReveal, "a media post paged onto words has nowhere to close")
        #expect(window.rowFrame(stage.window) != nil)
    }
}
