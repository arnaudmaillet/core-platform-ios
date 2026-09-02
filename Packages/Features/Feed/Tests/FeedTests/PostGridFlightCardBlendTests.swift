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
///
/// ⚠️ THE MOVING HALF IS THE LANDING, not the departure, and that is a change of
/// contract rather than a change of spelling. Fading the departure off works only
/// while the departure is the topmost thing drawn — and it stops being that the
/// moment a live surface is donated, which sits above both covers. The landing
/// then simply appeared in the frame the card was removed. So the landing gets
/// its own operand ABOVE the surface and rises into view, the departure never
/// moves, and one mechanism covers the still case and the video case.
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

    /// The order is part of the card's contract, and every position in it was
    /// paid for. The departure cover sits ABOVE the tile's cover and BELOW the
    /// live surface (on a dismissal that surface is the departing page's own
    /// moving picture and the cover is only its poster; burying it under a still
    /// would fly a frozen frame for the whole flight). The LANDING cover sits
    /// above the surface, which is the only position from which it can be seen
    /// to arrive at all. The three covers are private, so they are addressed by
    /// their position between the ones that are not — which pins the order as a
    /// side effect.
    @Test func theCardStacksItsFiveLayersInTheContractedOrder() {
        let card = makeCard()
        #expect(card.subviews.count == 5)
        #expect(card.subviews[2] === card.videoRenderView)
        #expect(card.subviews.last === card.zoomRestingChrome)
    }

    /// ⚠️ THE POSITION THE WHOLE FIX IS, restated against a DONATED surface
    /// rather than the placeholder one — because adoption re-inserts the surface
    /// (`insertSubview(_:aboveSubview:)`) and an insertion that landed on top
    /// would put the video back over the landing and restore the defect exactly.
    @Test func theLandingOperandStaysAboveADonatedLiveSurface() {
        let card = makeCard(.tile, kind: .video)
        let surface = VideoRenderView()
        card.adoptZoomLiveMediaView(surface)
        let landing = card.subviews.firstIndex { $0 === landingCover(of: card) }
        let donated = card.subviews.firstIndex { $0 === surface }
        #expect(donated != nil && landing != nil)
        #expect((donated ?? 0) < (landing ?? 0), "the landing cannot rise through the video")
    }

    private func tileCover(of card: PostGridFlightCard) -> UIView { card.subviews[0] }
    private func departureCover(of card: PostGridFlightCard) -> UIView { card.subviews[1] }
    /// Above the live surface, below the chrome — see the layer-order test.
    ///
    /// This is the PANE, which is what the blend moves. Its own subviews are the
    /// landing's still and, when one could be joined, the landing's live surface.
    private func landingCover(of card: PostGridFlightCard) -> UIView {
        card.subviews[card.subviews.count - 2]
    }

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
            #expect(isAlpha(landingCover(of: card), 0))
            #expect(isAlpha(card.videoRenderView, 1))
            #expect(isAlpha(chrome, 1))
            #expect(tileCover(of: card).isHidden == false)
            #expect(card.backgroundColor == floor)
        }
        #expect(departureCover(of: card).isHidden)
        #expect(landingCover(of: card).isHidden)
    }

    /// Handing the picture back as nil puts the card back where it started. A
    /// flight card is built fresh per transition today, but the channel is the
    /// same one an interrupted flight re-poses, and a stuck operand would haunt
    /// whatever the card is asked to be next.
    @Test func clearingTheDeparturePictureRestoresTheRestingCard() {
        let card = makeCard()
        card.setDeparturePicture(picture())
        card.setBlend(0.5)
        #expect(isAlpha(landingCover(of: card), 0.5))
        #expect(isAlpha(departureCover(of: card), 1))

        card.setDeparturePicture(nil)
        #expect(departureCover(of: card).isHidden)
        #expect(landingCover(of: card).isHidden)
        #expect(isAlpha(departureCover(of: card), 1))
        #expect(isAlpha(landingCover(of: card), 0))
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

    /// ⚠️ THE DEPARTURE NEVER MOVES. It is the picture the viewer is holding, and
    /// the rule for every transition on this screen is that the source is not
    /// faded — the destination is faded in over it. So the LANDING is the half
    /// that moves, from nothing at the page end to whole at the tile end.
    @Test func theLandingRisesOverADepartureThatNeverFades() {
        for style in [PostGridFlightCard.Style.tile, .listMedia] {
            let card = makeCard(style)
            card.setDeparturePicture(picture())

            card.setBlend(0)
            #expect(isAlpha(landingCover(of: card), 0))
            #expect(isAlpha(departureCover(of: card), 1))
            #expect(isAlpha(tileCover(of: card), 1))

            card.setBlend(1)
            #expect(isAlpha(landingCover(of: card), 1))
            #expect(isAlpha(departureCover(of: card), 1))
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
            #expect(isAlpha(departureCover(of: card), 1), "the source was faded")
            #expect(tileCover(of: card).isHidden == false)
            #expect(card.backgroundColor != UIColor.clear)
        }
    }

    @Test func theBlendClampsToTheUnitInterval() {
        let card = makeCard()
        card.setDeparturePicture(picture())
        card.setBlend(-0.5)
        #expect(isAlpha(landingCover(of: card), 0))
        card.setBlend(1.5)
        #expect(isAlpha(landingCover(of: card), 1))
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
        #expect(isAlpha(landingCover(of: card), 0))
        flying.setZoomContentBlend(1)
        #expect(isAlpha(landingCover(of: card), 1))
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
        #expect(isAlpha(landingCover(of: card), 0.75))
        #expect(isAlpha(departureCover(of: card), 1))
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
            #expect(isAlpha(landingCover(of: card), CGFloat(step) / 4))
            #expect(isAlpha(departureCover(of: card), 1))
            #expect(tileCover(of: card).isHidden == false)
            #expect(card.backgroundColor != UIColor.clear)
        }
    }

    // MARK: - The landing operand can be a PLAYER

    /// ⚠️ THE POINT OF THE PANE. A landing that is a clip deserves the clip:
    /// fading up its thumbnail is precisely "the destination arrives as a
    /// thumbnail". The live view goes ABOVE the still, so the still is only ever
    /// the floor for the instant before the surface has a frame.
    @Test func theLandingsLiveSurfaceSitsAboveItsStillInsideThePane() {
        let card = makeCard(.listMedia, kind: .video)
        card.setDeparturePicture(picture())
        let landing = VideoRenderView()
        card.setZoomLandingLiveMedia(landing)

        let pane = landingCover(of: card)
        #expect(pane.subviews.count == 2)
        #expect(pane.subviews.last === landing)
    }

    /// ⚠️ AND THE CARD NEVER WRITES ITS ALPHA — the same law the departure
    /// surface is held to, for the same reason: `revealOnFirstFrame` owns it.
    /// The PANE is what moves, so both operands ride one alpha that is nobody
    /// else's.
    @Test func theBlendNeverWritesTheLandingSurfacesAlpha() {
        let card = makeCard(.listMedia, kind: .video)
        card.setDeparturePicture(picture())
        let landing = VideoRenderView()
        card.setZoomLandingLiveMedia(landing)
        let owned = landing.alpha

        for step in 0...4 {
            card.setBlend(CGFloat(step) / 4)
            #expect(isAlpha(landing, owned), "the blend wrote an alpha the reveal owns")
            #expect(isAlpha(landingCover(of: card), CGFloat(step) / 4))
        }
    }

    /// A landing operand with no still behind it is still an operand — a row
    /// whose cover has not loaded must not lose its clip as well.
    @Test func aLiveLandingIsEnoughOnItsOwn() {
        let card = PostGridFlightCard(post: post(kind: .video), cover: nil, style: .listMedia)
        card.frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        card.layoutIfNeeded()
        card.setDeparturePicture(picture())
        card.setZoomLandingLiveMedia(VideoRenderView())

        card.setBlend(1)
        #expect(isAlpha(landingCover(of: card), 1))
        #expect(landingCover(of: card).isHidden == false)
    }

    /// ⚠️ POSED, NOT AUTORESIZED. The flight builds a card at staging and
    /// another for the animator, and one of them can be built before it has any
    /// bounds — autoresizing from 0x0 stays 0x0 for ever, because every delta it
    /// scales is zero. Measured as a landing operand installed into a pane of
    /// `{{0,0},{0,0}}`, which draws nothing at any blend.
    @Test func theLandingPaneTakesTheCardsSizeEvenWhenBuiltAtZero() {
        let card = PostGridFlightCard(post: post(kind: .video), cover: picture(), style: .listMedia)
        card.setDeparturePicture(picture())
        let landing = VideoRenderView()
        card.setZoomLandingLiveMedia(landing)
        #expect(landing.bounds.width == 0)

        card.frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        // Through the PROTOCOL channel, which is the one every pose runs and
        // therefore the one that carries the layout — `setBlend` alone moves the
        // alpha and nothing else.
        let flying: any ZoomFlightCard = card
        flying.setZoomContentBlend(0.5)
        #expect(landingCover(of: card).bounds.size == CGSize(width: Self.side, height: Self.side))
        #expect(landing.bounds.size == CGSize(width: Self.side, height: Self.side))
    }

    /// ⚠️ POSED BY TRANSFORM, NEVER RESIZED — the rule the DEPARTURE surface
    /// already follows, and the one this operand was breaking.
    ///
    /// An `AVSampleBufferDisplayLayer` does not re-render its video rect during
    /// an animated bounds change: inside a correctly sized, correctly centred
    /// surface the content stays drawn at its previous size, pinned to the layer
    /// origin. Filmed as the landing media letterboxing and sliding about inside
    /// the transition window.
    @Test func theLandingSurfaceIsPosedByTransformRatherThanResized() {
        let card = makeCard(.listMedia, kind: .video)
        card.setDeparturePicture(picture())
        let landing = VideoRenderView()
        card.setZoomLandingLiveMedia(landing)

        let flying: any ZoomFlightCard = card
        flying.setZoomContentBlend(0)
        let laidOut = landing.bounds.size
        #expect(laidOut.width > 0 && laidOut.height > 0)

        // A card sweeping to a very different shape, as a flight's does.
        card.frame = CGRect(x: 0, y: 0, width: 60, height: 200)
        flying.setZoomContentBlend(0.5)
        #expect(landing.bounds.size == laidOut, "the video layer was resized")
        #expect(landing.transform != .identity, "the surface was not posed at all")
        #expect(landing.center == CGPoint(x: 30, y: 100))
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

        #expect(isAlpha(landingCover(of: card), 0.25))
        card.setBlend(0.75)
        #expect(isAlpha(landingCover(of: card), 0.75))
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

/// The tile card's DEPARTURE cover, as geometry rather than as alpha.
///
/// It shares `DepartureCoverLayout` with the marker's card, and it is here for
/// a reason that only became visible once a video page could hand over a
/// picture at all: a tile's aspect is close to a page's, so re-cropping this
/// cover every frame recomputes almost the crop it had, and nobody has filmed
/// it. That is a property of the pictures that have reached it so far, not of
/// the code.
@MainActor
struct PostGridFlightCardDepartureGeometryTests {
    private func picture() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    private func card(at size: CGSize) -> PostGridFlightCard {
        let card = PostGridFlightCard(
            post: GalleryPost(
                id: PostID("m1"), kind: .photo, isRepost: false,
                thumbnailURL: nil, caption: "c", publishedAtMS: 0
            ),
            cover: picture(),
            style: .tile
        )
        card.frame = CGRect(origin: .zero, size: size)
        return card
    }

    private func departureCover(of card: PostGridFlightCard) -> UIView { card.subviews[1] }

    /// The page's picture shrinks whole into the tile, rather than being
    /// re-cropped to it at every size the card passes through.
    @Test func theDeparturePictureShrinksWholeRatherThanBeingRecropped() {
        let page = CGSize(width: 402, height: 874)
        let card = card(at: page)
        card.setDeparturePicture(picture())
        card.layoutIfNeeded()
        let cover = departureCover(of: card)
        #expect(abs(cover.frame.width - page.width) < 0.5, "precondition: it starts covering")

        let tile = CGSize(width: 128, height: 170)
        card.frame = CGRect(origin: .zero, size: tile)
        card.layoutIfNeeded()

        let shrunk = cover.frame.size
        #expect(shrunk.width >= tile.width - 0.5 && shrunk.height >= tile.height - 0.5,
                "the card showed its own ground: \(shrunk) does not cover \(tile)")
        #expect(abs(shrunk.width / shrunk.height - page.width / page.height) < 0.01,
                "the picture was re-cropped, not scaled")
    }


    /// ⚠️ THE FLIGHT POSES THE COVER WITHOUT A LAYOUT PASS, and this is the
    /// assertion — no `layoutIfNeeded()` anywhere below.
    ///
    /// Autoresizing used to carry the cover, and autoresizing is applied
    /// synchronously from inside `setBounds`, so it swept with an animated
    /// `card.frame` for free. The uniform scale replaced it with
    /// `layoutSubviews`, which UIKit DEFERS past the animation block that set
    /// the frame — so the cover snapped to its landing size on the flight's
    /// first frame and sat there as a small patch on a card still filling the
    /// screen. The reveal never showed it because `RevealStage.apply` calls
    /// `layoutIfNeeded()` from inside its own block; the flight has no such
    /// call, and every pose ends in `setZoomContentBlend`.
    ///
    /// A test that laid the card out itself would pass against the defect.
    @Test func theFlightPosesTheDepartureCoverWithoutALayoutPass() {
        let page = CGSize(width: 402, height: 874)
        let card = card(at: page)
        card.setDeparturePicture(picture())
        card.setZoomContentBlend(0)
        let cover = departureCover(of: card)
        #expect(abs(cover.frame.width - page.width) < 0.5, "precondition: it starts covering")

        // What a pose does: the frame, then the blend — inside an animation
        // block, where a deferred layout pass would not reach it.
        card.frame = CGRect(x: 0, y: 0, width: 128, height: 170)
        card.setZoomContentBlend(1)

        #expect(cover.frame.width < page.width - 1,
                "the cover did not follow the card down — it is waiting for a layout pass")
        #expect(abs(cover.frame.width / cover.frame.height - page.width / page.height) < 0.01,
                "the cover was re-cropped rather than scaled")
    }

    /// And a card that never grew is untouched — the flight path, posed by a
    /// transform and handed its cover before it is ever sized.
    @Test func aCardThatNeverGrewFillsItsBounds() {
        let side = CGSize(width: 56, height: 56)
        let card = card(at: side)
        card.setDeparturePicture(picture())
        card.layoutIfNeeded()

        #expect(abs(departureCover(of: card).frame.width - side.width) < 0.5)
        #expect(abs(departureCover(of: card).frame.height - side.height) < 0.5)
    }
}
