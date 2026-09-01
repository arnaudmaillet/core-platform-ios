import CoreModels
import CoreNavigation
import MediaPlayback
import PostGrid
import Testing
import UIKit
@testable import Feed

/// `PostGridFlightCard`'s picture channel, and everything it is required NOT to
/// touch.
///
/// A grid tile is a doorway into a paging feed, so the two ends of a flight are
/// routinely different pictures: dismiss five posts on and the card opens at full
/// screen wearing a cover the viewer last saw five posts ago. The blend gives the
/// card a second operand for that. What is pinned here is that it stays inert
/// without one, that exactly one operand is ever partly drawn, that the tile's
/// counters and badge are in neither operand, and that the alpha of a live
/// surface belongs to the reveal machinery rather than to this fade.
@MainActor
struct PostGridFlightCardBlendTests {
    private static let side: CGFloat = 130

    private func post(kind: GalleryPost.Kind = .photo) -> GalleryPost {
        GalleryPost(
            id: PostID("p1"),
            kind: kind,
            isRepost: false,
            thumbnailURL: nil,
            caption: "a caption",
            publishedAtMS: 0,
            reactionCount: 12,
            viewCount: 340
        )
    }

    private func makeCard(
        _ style: PostGridFlightCard.Style = .tile,
        kind: GalleryPost.Kind = .photo
    ) -> PostGridFlightCard {
        let card = PostGridFlightCard(post: post(kind: kind), cover: picture(), style: style)
        card.frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        card.layoutIfNeeded()
        return card
    }

    /// A real (tiny) bitmap rather than `UIImage()`: the blend keys off whether
    /// an image is present, and an empty one would satisfy that test while being
    /// nothing a viewer could see.
    private func picture() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    /// ⚠️ `UIView.alpha` rides `CALayer.opacity`, which is a `Float`, so a
    /// fractional CGFloat does not necessarily come back bit-identical — the
    /// `==`-on-CGFloat trap that has already turned a suite red on CI while it
    /// was green locally. Every alpha here is compared inside a tolerance far
    /// finer than a frame could show.
    private func isAlpha(_ view: UIView, _ expected: CGFloat) -> Bool {
        abs(view.alpha - expected) < 0.0001
    }

    // MARK: - Layer order

    /// The order is part of the card's contract. The departure cover sits ABOVE
    /// the tile's cover (the blend fades whichever operand is on top) and BELOW
    /// the live surface (on a dismissal that surface is the departing page's own
    /// moving picture and the cover is only its poster; burying it under a still
    /// would fly a frozen frame for the whole flight). The two covers are
    /// private, so they are addressed by their position between the ones that are
    /// not — which pins the order as a side effect.
    @Test func theCardStacksItsFourLayersInTheContractedOrder() {
        let card = makeCard()
        #expect(card.subviews.count == 4)
        #expect(card.subviews[2] === card.videoRenderView)
        #expect(card.subviews.last === card.zoomRestingChrome)
    }

    private func tileCover(of card: PostGridFlightCard) -> UIView { card.subviews[0] }
    private func departureCover(of card: PostGridFlightCard) -> UIView { card.subviews[1] }

    // MARK: - The un-blended card

    /// No departure picture, no blend. This is how the row of the product rule
    /// that must NOT blend gets there: a dismissal onto the post it left from is
    /// one picture at both ends, so there is nothing to blend against and a blend
    /// could only soften it. It hands in nil and keeps today's animation.
    @Test func aCardWithNoDeparturePictureIsUntouchedByTheBlend() throws {
        let card = makeCard()
        let chrome = try #require(card.zoomRestingChrome)
        let floor = card.backgroundColor
        for t in [CGFloat(0), 0.5, 1] {
            card.setBlend(t)
            #expect(isAlpha(tileCover(of: card), 1))
            #expect(isAlpha(departureCover(of: card), 1))
            #expect(isAlpha(card.videoRenderView, 1))
            #expect(isAlpha(chrome, 1))
            #expect(tileCover(of: card).isHidden == false)
            #expect(card.backgroundColor == floor)
        }
        #expect(departureCover(of: card).isHidden)
    }

    /// Handing the picture back as nil puts the card back where it started. A
    /// flight card is built fresh per transition today, but the channel is the
    /// same one an interrupted flight re-poses, and a stuck operand would haunt
    /// whatever the card is asked to be next.
    @Test func clearingTheDeparturePictureRestoresTheRestingCard() {
        let card = makeCard()
        card.setDeparturePicture(picture())
        card.setBlend(0.5)
        #expect(isAlpha(departureCover(of: card), 0.5))

        card.setDeparturePicture(nil)
        #expect(departureCover(of: card).isHidden)
        #expect(isAlpha(departureCover(of: card), 1))
        #expect(isAlpha(card.videoRenderView, 1))
        #expect(tileCover(of: card).isHidden == false)
    }

    /// A video card's floor is the dark stage its tile cell uses, and the blend
    /// must not repaint it — `applyContentFloor` restores the resting colour, not
    /// a guess at one.
    @Test func theFloorSurvivesADeparturePictureOnAVideoCard() {
        let card = makeCard(.tile, kind: .video)
        let floor = card.backgroundColor
        card.setDeparturePicture(picture())
        card.setBlend(0.5)
        #expect(card.backgroundColor == floor)
        card.setDeparturePicture(nil)
        #expect(card.backgroundColor == floor)
    }

    // MARK: - The blend's endpoints

    /// The page operand is on top of the tile's own cover, so it is the half that
    /// fades. The tile's cover is never touched, which is what keeps the landing
    /// handshake pixel-identical — the fix ADDS a second operand, it does not
    /// replace the card's picture.
    @Test func theDeparturePictureFadesOffTheTilesCover() {
        for style in [PostGridFlightCard.Style.tile, .listMedia] {
            let card = makeCard(style)
            card.setDeparturePicture(picture())

            card.setBlend(0)
            #expect(isAlpha(departureCover(of: card), 1))
            #expect(isAlpha(tileCover(of: card), 1))

            card.setBlend(1)
            #expect(isAlpha(departureCover(of: card), 0))
            #expect(isAlpha(tileCover(of: card), 1))
        }
    }

    /// ⚠️ THE INVARIANT THE FADE LAW ACTUALLY DEMANDS: exactly one operand's
    /// alpha moves and the one underneath stays fully opaque AND drawn, so every
    /// intermediate frame is an opaque sum of two pictures rather than two
    /// transparent ones over a hole.
    @Test func theOperandUnderneathIsNeverPartlyDrawn() {
        let card = makeCard()
        card.setDeparturePicture(picture())
        for step in 0...10 {
            card.setBlend(CGFloat(step) / 10)
            #expect(isAlpha(tileCover(of: card), 1))
            #expect(tileCover(of: card).isHidden == false)
            #expect(card.backgroundColor != UIColor.clear)
        }
    }

    @Test func theBlendClampsToTheUnitInterval() {
        let card = makeCard()
        card.setDeparturePicture(picture())
        card.setBlend(-0.5)
        #expect(isAlpha(departureCover(of: card), 1))
        card.setBlend(1.5)
        #expect(isAlpha(departureCover(of: card), 0))
    }

    /// The protocol channel is the same channel. ⚠️ Reached through the
    /// existential the flight actually holds: a member with no requirement behind
    /// it dispatches statically there, which is the trap
    /// `ZoomExistentialDispatchTests` stands guard over.
    @Test func theProtocolChannelReachesTheCardThroughTheExistential() {
        let card = makeCard()
        card.setDeparturePicture(picture())
        let flying: any ZoomFlightCard = card

        flying.setZoomContentBlend(0)
        #expect(isAlpha(departureCover(of: card), 1))
        flying.setZoomContentBlend(1)
        #expect(isAlpha(departureCover(of: card), 0))
    }

    // MARK: - The live surface is the page operand, and it is not in the fade

    /// ⚠️ THE ALPHA OF A LIVE SURFACE IS NOT THE CARD'S TO WRITE — the one place
    /// this card genuinely differs from `PinCardView`, which fades its video with
    /// its departure cover. A pin's surface only ever arrives by mirroring; this
    /// one arrives donated, through `revealOnFirstFrame`, whose whole job is to
    /// hold that alpha at 0 until a frame exists and take it to 1 the instant one
    /// lands. Blending the same property is two drivers on one layer, at a moment
    /// nothing here schedules.
    ///
    /// The reveal machinery's own value is what this asserts is left standing —
    /// 0 for the cold surface a headless test can make, which is precisely the
    /// value a blend would have overwritten.
    @Test func theBlendNeverWritesTheLiveSurfacesAlpha() {
        let card = makeCard(.tile, kind: .video)
        let surface = VideoRenderView()
        card.adoptZoomLiveMediaView(surface)
        card.setDeparturePicture(picture())
        let owned = surface.alpha

        for step in 0...4 {
            card.setBlend(CGFloat(step) / 4)
            #expect(isAlpha(surface, owned), "the blend wrote an alpha the reveal owns")
        }
    }

    /// A donation can arrive AFTER the departure picture — the flight keeps
    /// asking for as long as the answer could change — so the two orders have to
    /// agree. Adopting mid-flight leaves the blend exactly where it stood.
    @Test func aSurfaceAdoptedMidFlightLeavesTheBlendWhereItStood() {
        let card = makeCard(.tile, kind: .video)
        card.setDeparturePicture(picture())
        card.setBlend(0.75)

        card.adoptZoomLiveMediaView(VideoRenderView())
        #expect(isAlpha(departureCover(of: card), 0.25))
        #expect(tileCover(of: card).isHidden == false)
    }

    /// A hoisted dismissal is the case the blend is actually seen in with video
    /// in play: the host flies the page's surface itself and leaves this card
    /// holding nothing, so what lands is the cover pair — which means the card
    /// still needs the opaque floor the hot adopt took away.
    @Test func aCardThatHasHandedItsSurfaceAwayStillBlendsOnAnOpaqueFloor() {
        let card = makeCard(.tile, kind: .video)
        let surface = VideoRenderView()
        card.adoptZoomLiveMediaView(surface)
        card.setDeparturePicture(picture())
        UIView().addSubview(surface)

        for step in 0...4 {
            card.setBlend(CGFloat(step) / 4)
            #expect(isAlpha(departureCover(of: card), 1 - CGFloat(step) / 4))
            #expect(tileCover(of: card).isHidden == false)
            #expect(card.backgroundColor != UIColor.clear)
        }
    }

    // MARK: - Furniture belongs to neither operand

    /// ⚠️ THE TILE'S COUNTERS ARE TEXT, and text is what the fade law is about.
    /// They are also the tile's own furniture, with no page-side half to
    /// cross-fade against, so they belong to neither operand and keep the owner
    /// they already have: `zoomRestingChrome`, which the flight poses on a
    /// deliberately different clock — `poseInterpolated` excludes the chrome
    /// alphas and swaps them inside the release spring instead.
    @Test func theBlendNeverMovesTheCountersOrTheBadge() throws {
        let card = makeCard(.tile, kind: .video)
        let chrome = try #require(card.zoomRestingChrome)
        card.setDeparturePicture(picture())

        chrome.alpha = 0.5
        for step in 0...4 {
            card.setBlend(CGFloat(step) / 4)
            #expect(isAlpha(chrome, 0.5), "the blend dragged the tile's counters onto its clock")
            for furniture in chrome.subviews {
                #expect(isAlpha(furniture, 1))
            }
        }
    }

    /// And the reverse: the flight's chrome channel does not disturb a blend that
    /// is already set. The two write disjoint properties, so whichever runs second
    /// leaves the other's exactly where it was.
    @Test func theTwoChannelsDoNotOverwriteEachOther() throws {
        let card = makeCard()
        let chrome = try #require(card.zoomRestingChrome)
        card.setDeparturePicture(picture())
        card.setBlend(0.25)
        chrome.alpha = 0

        #expect(isAlpha(departureCover(of: card), 0.75))
        card.setBlend(0.75)
        #expect(isAlpha(departureCover(of: card), 0.25))
        #expect(isAlpha(chrome, 0))
    }

    /// A timeline row carries no furniture on its card at all — its caption,
    /// author line and metrics are drawn by the row BELOW the media. That is what
    /// leaves `.listMedia` with two pictures and nothing else, and it is why the
    /// blend is legal on this style too.
    @Test func aListMediaCardHasNoTextFurnitureToFade() throws {
        let card = makeCard(.listMedia, kind: .video)
        let chrome = try #require(card.zoomRestingChrome)
        let drawn = chrome.subviews.filter { !$0.isHidden }
        #expect(drawn.isEmpty)
    }
}
