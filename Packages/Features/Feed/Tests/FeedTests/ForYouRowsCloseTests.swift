import CoreModels
import CoreNavigation
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// How For You's Friends and Following rows CLOSE (2026-09-29, after #312).
///
/// Three reported defects, each pinned here at the seam that decides it:
///
/// 1. **Media card → text page → no grab, a chevron whose hero failed.** The
///    feed is a pager; once it is on words there is nothing to fly, and the
///    only driver that closes a card (`RowCardCloseLanding`) is armed only for
///    an origin that carries a window. The rows carried one for text posts
///    only. Every origin now carries it (`ForYouRowOrigins`).
/// 2. **The window came home beside the item.** A close measured the item
///    while the list's inset was drifting under the pop and while a press was
///    still scaling it. The close now pins the list and brings the item into
///    its row first, and the rect is the item AT REST.
/// 3. **A play glyph in the transition window** — see
///    `aFlightCardDrawsNoPlayGlyph`.
@MainActor
struct ForYouRowsCloseTests {
    // MARK: - 1. Every origin carries its window

    /// ⚠️ THE DEFECT. A card of ANY kind hands the flight a window, so a feed
    /// that pages onto a text post has a card close to arm — the grab and the
    /// chevron both have somewhere to go. The opening is unchanged: a picture
    /// still flies, words still open as the window.
    @Test(arguments: [GalleryPost.Kind.photo, .video, .text])
    func everyCardCarriesTheWindowItsCloseNeeds(kind: GalleryPost.Kind) throws {
        let tapped = Self.post("c-\(kind)", kind: kind)
        let fixture = Fixture(cards: [tapped, Self.post("after", kind: .text)])
        let origin = ForYouRowOrigins.card(
            tapped, stream: fixture.rails.cards, rails: fixture.rails,
            page: fixture.page, host: fixture.host.view
        )

        #expect(origin.hasHero == (kind != .text), "the opening is still chosen by the post")
        #expect(origin.textReveal != nil, "a \(kind) card offered no window for its close")
        let landing = FeedFeatureBuilder.cardCloseLanding(
            for: fixture.host, origin: origin, pipeline: nil, dock: { $0 }
        )
        #expect(landing is RowCardCloseLanding, "no card close would be armed beside the flight")
    }

    /// The same for a friend's story, whatever their first post is: a face
    /// opening onto a photograph closes onto the face from a text page too.
    @Test(arguments: [GalleryPost.Kind.photo, .text])
    func everyStoryCarriesTheWindowItsCloseNeeds(first kind: GalleryPost.Kind) throws {
        let story = Self.story("pal", posts: [Self.post("s1", kind: kind), Self.post("s2", kind: .text)])
        let fixture = Fixture(stories: [story])
        let origin = try #require(ForYouRowOrigins.story(
            story, rails: fixture.rails, page: fixture.page, host: fixture.host.view, pagePicture: nil
        ))

        #expect(origin.hasHero == (kind != .text))
        #expect(origin.textReveal != nil)
        #expect(FeedFeatureBuilder.cardCloseLanding(
            for: fixture.host, origin: origin, pipeline: nil, dock: { $0 }
        ) is RowCardCloseLanding)
    }

    /// The window a MEDIA card's close lands as is that card — its picture on
    /// the brick's floor, its size — not a text card that never sat in the row.
    @Test func aMediaCardsWindowLandsAsThePictureCard() throws {
        let tapped = Self.post("m", kind: .video)
        let fixture = Fixture(cards: [tapped])
        let reveal = try #require(ForYouRowOrigins.card(
            tapped, stream: [tapped], rails: fixture.rails, page: fixture.page, host: fixture.host.view
        ).textReveal)
        let row = try #require(reveal.rowFrame(fixture.host.view))
        let standIn = try #require(reveal.makeDismissStandIn(nil))

        #expect(standIn.bounds.size == row.size)
        #expect(standIn.backgroundColor == PostGridTileCell.fillColor(for: tapped))
        #expect(standIn.subviews.contains { $0 is UIImageView }, "the picture is missing")
        #expect(reveal.fill == PostGridTileCell.fillColor(for: tapped))
    }

    // MARK: - 2. The close measures the item where it rests

    /// Both closes — the flight's and the window's — pin the list's inset
    /// before they read a rect, and hand it back when they are over.
    @Test func bothClosesPinTheListAndHandItBack() throws {
        let tapped = Self.post("m", kind: .photo)
        let fixture = Fixture(cards: [tapped])
        let origin = ForYouRowOrigins.card(
            tapped, stream: [tapped], rails: fixture.rails, page: fixture.page, host: fixture.host.view
        )
        #expect(!fixture.isFrozen, "precondition")

        origin.willStageDismissal()
        #expect(fixture.isFrozen, "the flight measured an unpinned list")
        origin.setConcealed(false)
        #expect(!fixture.isFrozen, "the flight's landing kept the list pinned")

        let reveal = try #require(origin.textReveal)
        reveal.willStageDismissal(nil)
        #expect(fixture.isFrozen, "the window measured an unpinned list")
        reveal.dismissalDidEnd(false)
        #expect(!fixture.isFrozen, "a close that sprang back kept the list pinned")
    }

    /// A row scrolled under the open post is brought back before the close
    /// measures, so the card lands on a card in view rather than off the edge.
    @Test func aCardScrolledAwayIsBroughtBackBeforeTheCloseMeasures() throws {
        let cards = (0..<8).map { Self.post("c\($0)", kind: .photo) }
        let fixture = Fixture(cards: cards)
        let row = try #require(fixture.cardsRow)
        let origin = ForYouRowOrigins.card(
            cards[0], stream: cards, rails: fixture.rails, page: fixture.page, host: fixture.host.view
        )
        row.contentOffset.x = row.contentSize.width - row.bounds.width
        fixture.window.layoutIfNeeded()
        #expect(origin.frame(fixture.host.view) == nil, "precondition: the card scrolled away")

        origin.willStageDismissal()

        let landed = try #require(origin.frame(fixture.host.view))
        let rails = fixture.rails.convert(fixture.rails.bounds, to: fixture.host.view)
        #expect(rails.minX <= landed.minX && landed.maxX <= rails.maxX, "\(landed) is not wholly in view")
    }

    /// ⚠️ A PRESS SCALES THE ITEM; THE LANDING IS WHERE IT RESTS. A card whose
    /// cell (or content) wears a transform reports the rect it has at identity.
    @Test func aCardsLandingIgnoresATransformOnIt() throws {
        let tapped = Self.post("m", kind: .photo)
        let fixture = Fixture(cards: [tapped])
        let resting = try #require(fixture.rails.cardFrame(for: tapped.id, in: fixture.host.view))
        let cell = try #require(fixture.cardsRow?.visibleCells.first)

        cell.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        cell.contentView.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)

        #expect(fixture.rails.cardFrame(for: tapped.id, in: fixture.host.view) == resting)
        #expect(cell.convert(cell.bounds, to: fixture.host.view) != resting, "precondition: UIKit's own answer moves")
    }

    /// The arithmetic on its own: transforms below the ancestor are left out,
    /// a scroll view's offset (a bounds origin, not a transform) is honoured.
    @Test func theRestingFrameLeavesOutTransformsAndKeepsScrolling() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let row = UIScrollView(frame: CGRect(x: 0, y: 100, width: 400, height: 200))
        row.contentSize = CGSize(width: 1000, height: 200)
        row.contentOffset = CGPoint(x: 50, y: 0)
        root.addSubview(row)
        let cell = UIView(frame: CGRect(x: 60, y: 10, width: 100, height: 150))
        row.addSubview(cell)
        let content = UIView(frame: cell.bounds)
        cell.addSubview(content)
        let disc = UIView(frame: CGRect(x: 10, y: 10, width: 64, height: 64))
        content.addSubview(disc)
        content.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        disc.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)

        let resting = ForYouRailsView.restingFrame(of: disc, below: row, in: root)

        // disc (10,10) in content → cell (10,10) → row content (70,20) → root:
        // minus the row's offset, plus its origin.
        #expect(resting == CGRect(x: 20, y: 120, width: 64, height: 64))
        #expect(disc.convert(disc.bounds, to: root) != resting, "precondition: UIKit's answer is scaled")
    }

    /// And the flight hands the origin its staging FIRST — before the rect the
    /// close flies to is read.
    @Test func theFlightStagesItsOriginBeforeItMeasures() {
        var events: [String] = []
        let origin = SnapFeedHeroOrigin(
            post: Self.post("m", kind: .photo),
            cover: nil,
            style: .listMedia,
            frame: { _ in events.append("frame"); return CGRect(x: 1, y: 2, width: 3, height: 4) },
            isOnScreen: { true },
            setConcealed: { _ in },
            willStageDismissal: { events.append("stage") }
        )
        let source = ExternalHeroZoomSource(origin: origin)

        source.zoomSourceWillStageDismissal()
        _ = source.zoomHeroFrame(in: UIView())

        #expect(events == ["stage", "frame"])
    }

    // MARK: - 3. No play glyph in any transition window

    /// ⚠️ THE CARD IS THE TILE'S TWIN, and the tile draws no play glyph — so
    /// neither does the card, at either end of a flight, for any post. The
    /// brick's one count (reach, trailing foot) is all its furniture.
    @Test(arguments: [GalleryPost.Kind.video, .photo])
    func aFlightCardDrawsNoPlayGlyph(kind: GalleryPost.Kind) throws {
        for style in [PostGridFlightCard.Style.tile, .listMedia] {
            let card = PostGridFlightCard(post: Self.post("p", kind: kind), cover: nil, style: style)
            card.frame = CGRect(x: 0, y: 0, width: 130, height: 130)
            card.layoutIfNeeded()
            let chrome = try #require(card.zoomRestingChrome)

            #expect(!Self.drawsPlayGlyph(card), "\(style) \(kind) flies a play glyph")
            #expect(chrome.subviews.count == (style == .tile ? 1 : 0))
            if style == .tile, let count = chrome.subviews.first {
                #expect(abs(count.frame.maxX - (130 - 8)) < 0.5, "the count sits where the tile's does")
            }
        }
    }

    // MARK: - Fixtures

    private static func post(_ id: String, kind: GalleryPost.Kind) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: kind, isRepost: false,
            thumbnailURL: kind == .text ? nil : URL(string: "https://example.com/\(id).jpg"),
            caption: "caption \(id)", publishedAtMS: 1,
            authorID: ProfileID("bo"), authorName: "Bo", authorHandle: "bo"
        )
    }

    private static func story(_ handle: String, posts: [GalleryPost]) -> ForYouViewModel.FriendStory {
        ForYouViewModel.FriendStory(
            authorID: ProfileID(handle), name: handle.capitalized, handle: handle,
            avatarURL: nil, posts: posts, hasUnseen: true
        )
    }

    private static func drawsPlayGlyph(_ view: UIView) -> Bool {
        if let image = (view as? UIImageView)?.image, !view.isHidden,
           image.isSymbolImage, String(describing: image).contains("play") {
            return true
        }
        return view.subviews.contains(where: drawsPlayGlyph)
    }

    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    /// The rows in a real window, laid out, over the list page they lead.
    @MainActor
    private final class Fixture {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let host = UIViewController()
        let rails: ForYouRailsView
        let page: ForYouGridPage

        init(cards: [GalleryPost] = [], stories: [ForYouViewModel.FriendStory] = []) {
            let pipeline = ImagePipeline(fetcher: SilentFetcher())
            rails = ForYouRailsView(imagePipeline: pipeline, videoPlayback: nil)
            page = ForYouGridPage(imagePipeline: pipeline, style: .discover, videoPlayback: nil)
            // Rendered before it has a window, so the rows apply unanimated.
            var model = ForYouViewModel.Rails()
            model.following = cards
            model.friends = stories
            rails.render(model)
            window.rootViewController = host
            window.isHidden = false
            page.frame = host.view.bounds
            host.view.addSubview(page)
            rails.frame = CGRect(
                x: 0, y: 120, width: 402,
                height: ForYouRailsView.height(forWidth: 402, friends: stories.count, following: cards.count)
            )
            host.view.addSubview(rails)
            window.layoutIfNeeded()
            rails.layoutIfNeeded()
            for row in rails.subviews.compactMap({ $0 as? UICollectionView }) { row.layoutIfNeeded() }
        }

        /// The Following row — the second of the rows' two scroll views.
        var cardsRow: UICollectionView? {
            rails.subviews.compactMap { $0 as? UICollectionView }.last
        }

        var isFrozen: Bool { page.debugInsetState.contains("frozen=Y") }
    }
}
