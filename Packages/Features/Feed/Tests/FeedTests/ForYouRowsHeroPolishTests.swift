import CoreModels
import CoreNavigation
import FeedInterface
import Foundation
import MediaCore
import MediaPlayback
import PostGrid
import Testing
import UIKit
@testable import Feed

/// Three defects filmed on For You's rows after #314, each pinned at the seam
/// that decides it.
///
/// 1. **A Following card's caption grew out of the window's top-left corner**
///    on a close (and a text card's words did the same in its window). The
///    caption a transition carries is wrapped ONCE, at the card's size, and
///    then only posed — pinned to the window's edges, scaled with it.
/// 2. **A thumbnail flashed at a video card's landing.** The row now takes the
///    page's playback onto the card before the flight card goes, and the
///    flight card waits for it to draw.
/// 3. **A friend's story flew their face with no media in the window.** The
///    post's picture is loaded when the cache is cold, a face with a cold
///    cache is still a face at the close, and the page's live video is an
///    operand the face rises over.
@MainActor
struct ForYouRowsHeroPolishTests {
    private static let card = CGSize(width: 150, height: 200)
    private static let page = CGSize(width: 402, height: 874)

    // MARK: - 1. The caption is anchored, never re-laid out

    /// Over a picture: at the page's size the words keep the card's wrap and
    /// sit on the window's FOOT, scaled with its width — and back at the
    /// card's size they are exactly where the card in the row draws them.
    @Test func aPicturesCaptionKeepsItsWrapAndHangsFromTheFoot() {
        let overlay = ForYouCardCaptionOverlay(
            post: Self.post("m", kind: .photo), placement: .onMedia, referenceSize: Self.card
        )
        overlay.layoutIfNeeded()
        let resting = overlay.debugCaptionFrame
        let restingAuthor = overlay.debugAuthorFrame
        #expect(abs(resting.maxY - (Self.card.height - 10)) < 0.5, "precondition: the card's own layout")

        overlay.frame = CGRect(origin: .zero, size: Self.page)
        overlay.layoutIfNeeded()
        let scale = Self.page.width / Self.card.width
        let caption = overlay.debugCaptionFrame

        #expect(abs(overlay.debugCaptionWrapWidth - resting.width) < 0.5, "the caption re-wrapped at the window's width")
        #expect(abs(caption.maxY - (Self.page.height - 10 * scale)) < 0.5, "the caption left the window's foot")
        #expect(abs(caption.minX - 10 * scale) < 0.5, "the caption left the window's leading edge")
        #expect(abs(caption.width - resting.width * scale) < 0.5, "the caption is not scaled with the window")
        #expect(overlay.debugAuthorFrame.maxY < caption.minY, "the author fell under the caption")

        overlay.frame = CGRect(origin: .zero, size: Self.card)
        overlay.layoutIfNeeded()
        #expect(Self.near(overlay.debugCaptionFrame, resting), "the landing is not the card's own caption")
        #expect(Self.near(overlay.debugAuthorFrame, restingAuthor))
    }

    /// Words on the card (`.onCard`, a text post's long-press preview): its
    /// words hang from the window's TOP, its author from the FOOT — the four
    /// corners of the window carry the card's two ends.
    @Test func aTextCardsWordsHangFromTheTopAndItsAuthorFromTheFoot() {
        let overlay = ForYouCardCaptionOverlay(
            post: Self.post("t", kind: .text), placement: .onCard, referenceSize: Self.card
        )
        overlay.layoutIfNeeded()
        let resting = overlay.debugCaptionFrame

        overlay.frame = CGRect(origin: .zero, size: Self.page)
        overlay.layoutIfNeeded()
        let scale = Self.page.width / Self.card.width

        #expect(abs(overlay.debugCaptionFrame.minY - resting.minY * scale) < 0.5, "the words left the window's top")
        #expect(abs(overlay.debugAuthorFrame.maxY - (Self.page.height - 10 * scale)) < 0.5,
                "the author left the window's foot")
        #expect(abs(overlay.debugCaptionWrapWidth - resting.width) < 0.5)
    }

    /// The author's face (2026-09-30): a disc as tall as the name's line, just
    /// before the name, on both placements — and posed with the name, so at
    /// the page's size it is still on the name's line at the window's foot.
    @Test func theAuthorsDiscLeadsTheNameAtTheNamesHeight() {
        for (kind, placement) in [(GalleryPost.Kind.photo, ForYouCardCaptionOverlay.Placement.onMedia),
                                  (.text, .onCard)] {
            let overlay = ForYouCardCaptionOverlay(
                post: Self.post("a", kind: kind), placement: placement, referenceSize: Self.card
            )
            overlay.layoutIfNeeded()
            let disc = overlay.debugAvatarFrame
            let author = overlay.debugAuthorFrame
            #expect(abs(disc.height - author.height) < 0.5, "the disc is the name's line tall")
            #expect(abs(disc.width - disc.height) < 0.5, "a disc, not an oval")
            #expect(abs(disc.midY - author.midY) < 0.5, "on the name's line")
            #expect(disc.maxX <= author.minX && author.minX - disc.maxX < 8, "just before the name")
            #expect(abs(disc.minX - 10) < 0.5, "at the card's leading inset, where the name used to start")

            overlay.frame = CGRect(origin: .zero, size: Self.page)
            overlay.layoutIfNeeded()
            let scale = Self.page.width / Self.card.width
            #expect(abs(overlay.debugAvatarFrame.height - disc.height * scale) < 0.5, "scaled with the window")
            #expect(abs(overlay.debugAvatarFrame.midY - overlay.debugAuthorFrame.midY) < 0.5,
                    "the disc left the name's line in the window")
        }
    }

    /// A COPY draws the face the card already has: the picture straight from
    /// the pipeline's memory, so the flight's resting overlay takes off with
    /// the card's face, not its initials.
    @Test func aCopyDrawsTheFaceFromMemory() async {
        let pipeline = ImagePipeline(fetcher: SilentFetcher())
        let face = URL(string: "https://example.com/bo.jpg")!
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        pipeline.store(picture, for: face)
        var post = Self.post("f", kind: .photo)
        post.authorAvatarURL = face
        let copy = ForYouFollowingCardCell.makeOverlay(for: post, restingSize: Self.card, imagePipeline: pipeline)
        #expect(copy.debugShowsAvatarPicture)
        let bare = ForYouFollowingCardCell.makeOverlay(for: Self.post("g", kind: .photo), restingSize: Self.card)
        #expect(!bare.debugShowsAvatarPicture, "no picture named: the initials alone")
        #expect(!bare.debugAvatarFrame.isNull)
    }

    /// ⚠️ THE UNFOLD ITSELF. A caption whose first layout pass runs inside
    /// someone else's animation block grows out of a zero rect — the "text
    /// from the top-left" of the report. The first pose never animates,
    /// whoever's block it lands in; every later one rides it.
    @Test func theFirstPoseIsNeverAnimatedAndTheNextRidesTheBlock() throws {
        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.page))
        window.isHidden = false
        let overlay = ForYouCardCaptionOverlay(
            post: Self.post("m", kind: .photo), placement: .onMedia, referenceSize: Self.card
        )
        window.addSubview(overlay)

        UIView.animate(withDuration: 1) {
            overlay.frame = CGRect(origin: .zero, size: Self.page)
            overlay.layoutIfNeeded()
        }
        #expect(overlay.subviews.allSatisfy { $0.layer.animationKeys() == nil },
                "the first pose grew out of nothing inside the block")

        UIView.animate(withDuration: 1) {
            overlay.frame = CGRect(origin: .zero, size: Self.card)
            overlay.layoutIfNeeded()
        }
        #expect(overlay.subviews.contains { !($0.layer.animationKeys() ?? []).isEmpty },
                "a later pose did not ride the window's block — the probe proves nothing")
        overlay.removeFromSuperview()
    }

    /// The flight's copy, on a close: laid out at the page end outside the
    /// flight, then posed INSIDE the block that shrinks the card — so its words
    /// travel with the window rather than jumping to their landing.
    @Test func theFlightCardPosesItsCaptionInsideTheFlightsBlock() throws {
        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.page))
        window.isHidden = false
        let post = Self.post("v", kind: .video)
        let card = PostGridFlightCard(post: post, cover: nil, style: .listMedia)
        card.installRestingOverlay(ForYouFollowingCardCell.makeOverlay(for: post, restingSize: Self.card))
        window.addSubview(card)
        UIView.performWithoutAnimation {
            card.frame = CGRect(origin: .zero, size: Self.page)
            card.setZoomContentBlend(0)
            card.layoutIfNeeded()
        }
        let overlay = try #require(card.zoomRestingChrome?.subviews.first as? ForYouCardCaptionOverlay)
        let scale = Self.page.width / Self.card.width
        #expect(abs(overlay.debugCaptionFrame.maxY - (Self.page.height - 10 * scale)) < 0.5,
                "the page end is not anchored at the foot")

        UIView.animate(withDuration: 1) {
            card.frame = CGRect(x: 20, y: 300, width: Self.card.width, height: Self.card.height)
            card.setZoomContentBlend(1)
        }
        #expect(overlay.subviews.contains { !($0.layer.animationKeys() ?? []).isEmpty },
                "the caption jumped to its landing outside the flight")
        #expect(abs(overlay.debugCaptionFrame.maxY - (Self.card.height - 10)) < 0.5)
        card.removeFromSuperview()
    }

    /// A media card's window stand-in, built for a close: its words are laid
    /// out at the card's size BEFORE the window ever resizes it. (The text
    /// card's stand-in is the list's, `RevealDismissCardView`, since the
    /// Following row's text cards became the list's card.)
    @Test func aStandInArrivesLaidOut() throws {
        let standIn = ForYouFollowingCardCell.makeStandIn(
            for: Self.post("p", kind: .photo), cover: nil, size: Self.card
        )
        let overlay = try #require(standIn.subviews.compactMap { $0 as? ForYouCardCaptionOverlay }.first)
        #expect(overlay.debugCaptionFrame.width > 0, "the stand-in's words meet their first layout in the window")
        #expect(abs(overlay.debugCaptionFrame.maxY - (Self.card.height - 10)) < 0.5)
    }

    // MARK: - 2. The landing takes the playback

    /// A Following card's close hands its landing to the row and waits on it;
    /// a source with nothing to say keeps today's landing.
    @Test func aCardsCloseHandsItsLandingToTheRow() {
        var adopted = 0
        var ready = false
        let origin = SnapFeedHeroOrigin(
            post: Self.post("v", kind: .video), cover: nil, style: .listMedia,
            frame: { _ in .zero }, isOnScreen: { true }, setConcealed: { _ in },
            adoptLandingLiveMedia: { _ in adopted += 1 },
            landingMediaIsReady: { ready }
        )
        let source = ExternalHeroZoomSource(origin: origin)
        source.zoomAdoptLiveMediaView(UIView())
        #expect(adopted == 1)
        #expect(!source.zoomLandingMediaIsReady, "the flight card would leave before the card draws")
        ready = true
        #expect(source.zoomLandingMediaIsReady)

        let silent = ExternalHeroZoomSource(origin: SnapFeedHeroOrigin(
            post: Self.post("p", kind: .photo), cover: nil, style: .listMedia,
            frame: { _ in .zero }, isOnScreen: { true }, setConcealed: { _ in }
        ))
        #expect(silent.zoomLandingMediaIsReady)
    }

    /// The rows' own origin wires both — and a card that adopted nothing is
    /// ready on its cover, never held for a clip nobody is playing.
    @Test func theRowsCardOriginWiresTheLanding() throws {
        let tapped = Self.post("v", kind: .video)
        let fixture = Fixture(cards: [tapped])
        let origin = ForYouRowOrigins.card(
            tapped, stream: [tapped], rails: fixture.rails, page: fixture.page, host: fixture.host.view
        )
        #expect(origin.adoptLandingLiveMedia != nil)
        let ready = try #require(origin.landingMediaIsReady)
        // No playback in the fixture and no cover loaded: nothing adopted, so
        // the answer is the cover's, not a clip's.
        #expect(ready() == fixture.rails.isLandingPlaybackReady(for: tapped.id))
    }

    // MARK: - 3. A face flies the post's media

    /// ⚠️ A FACE WITH A COLD CACHE IS STILL A FACE. The tap's peek missed, so
    /// `pagePicture` is nil — which the close used to read as "a tile", and
    /// flew the face alone. It now asks for the picture of the post the viewer
    /// ENDED on (a video page has no still of its own).
    @Test func aFacesCloseAsksForThePictureOfThePostItLeaves() throws {
        let posts = [Self.post("s1", kind: .photo), Self.post("s2", kind: .video)]
        var asked: [PostID] = []
        let origin = SnapFeedHeroOrigin(
            post: posts[0], stream: posts, cover: Self.picture(.systemYellow), style: .listMedia,
            frame: { _ in .zero }, isOnScreen: { true }, setConcealed: { _ in },
            cornerRadius: 32, pagePicture: nil,
            pagePictureOf: { id, _ in asked.append(id); return id == posts[1].id ? Self.picture(.systemTeal) : nil }
        )
        let source = ExternalHeroZoomSource(origin: origin, settle: { (id: posts[1].id, cover: nil) })

        source.zoomSourceWillStageDismissal()
        let card = try #require(source.makeZoomFlightCard() as? PostGridFlightCard)

        #expect(asked == [posts[1].id], "the close asked about the wrong post")
        #expect(Self.departureCover(of: card).isHidden == false, "the face flew home alone")
    }

    /// The opening's picture, loaded after take-off, reaches the card in the
    /// air — dissolving from the face rather than cutting to the page.
    @Test func aFacesOpeningTakesALatePictureMidAir() throws {
        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.page))
        window.isHidden = false
        var late: ((UIImage) -> Void)?
        let first = Self.post("s1", kind: .photo)
        let origin = SnapFeedHeroOrigin(
            post: first, stream: [first], cover: Self.picture(.systemYellow), style: .listMedia,
            frame: { _ in .zero }, isOnScreen: { true }, setConcealed: { _ in },
            cornerRadius: 32, pagePicture: nil,
            pagePictureOf: { _, arrived in late = arrived; return nil }
        )
        let source = ExternalHeroZoomSource(origin: origin)
        let card = try #require(source.makeZoomFlightCard() as? PostGridFlightCard)
        window.addSubview(card)
        card.frame = CGRect(origin: .zero, size: Self.page)
        card.setZoomContentBlend(0)
        #expect(Self.departureCover(of: card).isHidden, "precondition: nothing to blend yet")

        let arrive = try #require(late, "the opening never asked for the picture")
        arrive(Self.picture(.systemTeal))

        let pane = Self.landingPane(of: card)
        #expect(!Self.departureCover(of: card).isHidden)
        #expect(!pane.isHidden)
        #expect(abs(pane.alpha) < 0.0001, "the pane must end at the page end")
        #expect(pane.layer.animationKeys()?.isEmpty == false, "the late picture cut in instead of dissolving")
        card.removeFromSuperview()
    }

    /// With no still at all, a face flying the page's VIDEO still blends: the
    /// face rises over the clip instead of cutting to it in the landing frame.
    /// A tile flying its own post's video is untouched.
    @Test func aFaceBlendsOverThePagesVideoWithNoStill() {
        let face = PostGridFlightCard(
            post: Self.post("s", kind: .video), cover: Self.picture(.systemYellow),
            style: .listMedia, cornerRadius: 32, drawsPost: false
        )
        face.frame = CGRect(origin: .zero, size: Self.card)
        face.adoptZoomLiveMediaView(VideoRenderView())
        face.setZoomContentBlend(1)
        #expect(!Self.landingPane(of: face).isHidden, "the face has nothing to rise over")
        #expect(abs(Self.landingPane(of: face).alpha - 1) < 0.0001)
        face.setZoomContentBlend(0)
        #expect(abs(Self.landingPane(of: face).alpha) < 0.0001)

        let tile = PostGridFlightCard(
            post: Self.post("t", kind: .video), cover: Self.picture(.systemYellow), style: .listMedia
        )
        tile.frame = CGRect(origin: .zero, size: Self.card)
        tile.adoptZoomLiveMediaView(VideoRenderView())
        tile.setZoomContentBlend(1)
        #expect(Self.landingPane(of: tile).isHidden, "a tile flying its own video started blending")
    }

    // MARK: - 4. A story's opening is live, not a poster

    /// A face that can donate nothing flies no player, so it says so and the
    /// page decodes from take-off; every source that can donate — a Following
    /// card — and every source that draws its own post keeps the default.
    @Test func aStoryFliesNoPlayerSoThePageDecodesFromTakeOff() {
        let post = Self.post("s", kind: .video)
        func origin(face: Bool, donates: Bool) -> SnapFeedHeroOrigin {
            SnapFeedHeroOrigin(
                post: post, cover: Self.picture(.systemYellow), style: .listMedia,
                frame: { _ in nil }, isOnScreen: { false }, setConcealed: { _ in },
                donateLiveMedia: donates ? { nil } : nil,
                cornerRadius: face ? 32 : nil,
                pagePictureOf: face ? { _, _ in nil } : nil
            )
        }
        #expect(ExternalHeroZoomSource(origin: origin(face: true, donates: false))
            .zoomFlightCarriesLivePlayer == false, "a story held the page's playback back for a player it never flies")
        #expect(ExternalHeroZoomSource(origin: origin(face: false, donates: true)).zoomFlightCarriesLivePlayer)
        #expect(ExternalHeroZoomSource(origin: origin(face: false, donates: false)).zoomFlightCarriesLivePlayer)
    }

    /// The page's player, MIRRORED onto a face's card mid-flight, is the far
    /// end of the blend: the face rises over it, it is held out of sight while
    /// the card travels, and it arrives by fading up once it has a frame —
    /// never by cutting in.
    @Test func aFaceMirroringThePagesPlayerDissolvesToIt() throws {
        let face = PostGridFlightCard(
            post: Self.post("s", kind: .video), cover: Self.picture(.systemYellow),
            style: .listMedia, cornerRadius: 32, drawsPost: false
        )
        face.frame = CGRect(origin: .zero, size: Self.card)
        face.adoptZoomLiveMedia { _ in true }
        let surface = try #require(face.zoomLiveMediaSurface as? VideoRenderView)
        face.setZoomContentBlend(1)
        #expect(!Self.landingPane(of: face).isHidden, "the face has nothing to rise over")
        #expect(abs(Self.landingPane(of: face).alpha - 1) < 0.0001)
        face.setZoomContentBlend(0)
        #expect(abs(Self.landingPane(of: face).alpha) < 0.0001, "the page end still shows the face")

        face.holdAdoptedLiveMediaUntilLanding()
        #expect(surface.isHidden, "a surface adopted mid-flight was shown before the landing")
        face.fadeInAdoptedLiveMedia(over: 0.2)
        #expect(!surface.isHidden, "the arrival left the surface hidden")
        #expect(surface.alpha < 0.0001, "the surface showed before it had a frame")

        // A card that draws its own post does not start blending over it.
        let tile = PostGridFlightCard(
            post: Self.post("t", kind: .video), cover: Self.picture(.systemYellow), style: .listMedia
        )
        tile.frame = CGRect(origin: .zero, size: Self.card)
        tile.adoptZoomLiveMedia { _ in true }
        tile.setZoomContentBlend(1)
        #expect(Self.landingPane(of: tile).isHidden, "a tile mirroring its own post started blending")
    }

    // MARK: - Fixtures

    private static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5
            && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    /// The card's stack, by position — see `PostGridFlightCardBlendTests`.
    private static func departureCover(of card: PostGridFlightCard) -> UIView { card.subviews[1] }
    private static func landingPane(of card: PostGridFlightCard) -> UIView {
        card.subviews[card.subviews.count - 2]
    }

    private static func picture(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    private static func post(_ id: String, kind: GalleryPost.Kind) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: kind, isRepost: false,
            thumbnailURL: kind == .text ? nil : URL(string: "https://example.com/\(id).jpg"),
            caption: "a caption long enough to wrap onto a second line on a card \(id)",
            publishedAtMS: 1,
            authorID: ProfileID("bo"), authorName: "Bo", authorHandle: "bo"
        )
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

        init(cards: [GalleryPost]) {
            let pipeline = ImagePipeline(fetcher: SilentFetcher())
            rails = ForYouRailsView(imagePipeline: pipeline, videoPlayback: nil)
            page = ForYouGridPage(imagePipeline: pipeline, style: .discover, videoPlayback: nil)
            var model = ForYouViewModel.Rails()
            model.following = cards
            rails.render(model)
            window.rootViewController = host
            window.isHidden = false
            page.frame = host.view.bounds
            host.view.addSubview(page)
            rails.frame = CGRect(x: 0, y: 120, width: 402, height: rails.preferredHeight(forWidth: 402))
            host.view.addSubview(rails)
            window.layoutIfNeeded()
            rails.layoutIfNeeded()
            for row in rails.subviews.compactMap({ $0 as? UICollectionView }) { row.layoutIfNeeded() }
        }
    }
}
