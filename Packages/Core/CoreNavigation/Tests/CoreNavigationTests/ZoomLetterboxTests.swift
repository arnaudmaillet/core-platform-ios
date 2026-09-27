import Testing
import UIKit
@testable import CoreNavigation

/// The letterboxed hero: a destination that draws its picture aspect-FIT
/// (`zoomTargetMediaFrame`) gets a flight whose picture lands on that rect,
/// while the page rect keeps the chrome — and a destination that says nothing
/// gets exactly the flight it always had.
///
/// Geometry first (pure), then `ZoomFlight` built both ways and posed at both
/// ends. The poses are plain view mutations, so a card in no window is enough
/// to assert where each piece lands.
@MainActor
struct ZoomLetterboxTests {
    private let page = CGRect(x: 0, y: 0, width: 402, height: 874)
    /// A 9:16 clip fitted into the page: full width, bands above and below.
    private var media: CGRect { ZoomTransitionGeometry.fittedMediaRect(aspect: CGSize(width: 9, height: 16), in: page)! }
    private let tile = CGRect(x: 8, y: 445, width: 243, height: 246)

    // MARK: - fittedMediaRect

    @Test func aPortraitPictureFillsTheWidthAndIsCentredVertically() {
        let rect = ZoomTransitionGeometry.fittedMediaRect(aspect: CGSize(width: 1080, height: 1440), in: page)!
        #expect(abs(rect.width - 402) < 0.001)
        #expect(abs(rect.height - 536) < 0.001)
        #expect(abs(rect.midY - page.midY) < 0.001)
        #expect(rect.minX == 0)
    }

    @Test func aLandscapePictureGetsTheTallBands() {
        let rect = ZoomTransitionGeometry.fittedMediaRect(aspect: CGSize(width: 1440, height: 1080), in: page)!
        #expect(abs(rect.width - 402) < 0.001)
        #expect(abs(rect.height - 301.5) < 0.001)
        #expect(abs(rect.minY - (874 - 301.5) / 2) < 0.001)
    }

    /// A picture TALLER than the screen letterboxes on the other axis — the
    /// bands go left and right.
    @Test func aPictureTallerThanThePageGetsSideBands() {
        let rect = ZoomTransitionGeometry.fittedMediaRect(aspect: CGSize(width: 1, height: 3), in: page)!
        #expect(abs(rect.height - 874) < 0.001)
        #expect(abs(rect.width - 874 / 3) < 0.001)
        #expect(abs(rect.midX - page.midX) < 0.001)
    }

    @Test func aDegenerateAspectOrPageHasNoRect() {
        #expect(ZoomTransitionGeometry.fittedMediaRect(aspect: .zero, in: page) == nil)
        #expect(ZoomTransitionGeometry.fittedMediaRect(aspect: CGSize(width: 0, height: 5), in: page) == nil)
        #expect(ZoomTransitionGeometry.fittedMediaRect(aspect: CGSize(width: 4, height: 3), in: .zero) == nil)
    }

    // MARK: - letterboxedMediaRect: when a flight letterboxes at all

    @Test func noRectAndThePageItselfBothMeanNoLetterbox() {
        #expect(ZoomTransitionGeometry.letterboxedMediaRect(nil, in: page) == nil)
        #expect(ZoomTransitionGeometry.letterboxedMediaRect(page, in: page) == nil)
        // A rounding error's worth of difference is still the page.
        #expect(ZoomTransitionGeometry.letterboxedMediaRect(page.insetBy(dx: 0.2, dy: 0.2), in: page) == nil)
    }

    @Test func aRectOutsideThePageOrWithoutAreaIsRefused() {
        #expect(ZoomTransitionGeometry.letterboxedMediaRect(CGRect(x: 0, y: -40, width: 402, height: 900), in: page) == nil)
        #expect(ZoomTransitionGeometry.letterboxedMediaRect(CGRect(x: 0, y: 80, width: 402, height: 0), in: page) == nil)
    }

    @Test func aFittedRectLetterboxes() {
        #expect(ZoomTransitionGeometry.letterboxedMediaRect(media, in: page) == media)
    }

    // MARK: - The box around the picture

    @Test func theBoxIsThePageAtThePageEnd() {
        let box = ZoomTransitionGeometry.letterboxCardFrame(forMedia: media, page: page, media: media)
        #expect(Self.near(box, page))
        let inner = ZoomTransitionGeometry.letterboxMediaFrame(inCardOfSize: page.size, page: page, media: media)
        #expect(Self.near(inner, media))
    }

    /// The two mappings are inverses at every size, so the picture sits at the
    /// tile's rect exactly when the box is posed for it.
    @Test func theBoxAndThePictureRoundTripAtAnyRect() {
        for rect in [tile, CGRect(x: 300, y: 600, width: 56, height: 56), CGRect(x: 10, y: 20, width: 300, height: 90)] {
            let box = ZoomTransitionGeometry.letterboxCardFrame(forMedia: rect, page: page, media: media)
            let inner = ZoomTransitionGeometry.letterboxMediaFrame(inCardOfSize: box.size, page: page, media: media)
            #expect(Self.near(inner.offsetBy(dx: box.minX, dy: box.minY), rect))
            // Page-shaped per axis: the box is to the rect what the page is to
            // the picture.
            #expect(abs(box.width / rect.width - page.width / media.width) < 0.0001)
            #expect(abs(box.height / rect.height - page.height / media.height) < 0.0001)
        }
    }

    // MARK: - ZoomFlight, flag off: nothing changes

    @Test func withoutAMediaRectTheFlightIsTheSourceCardAlone() {
        let card = LetterboxProbeCard()
        let flight = Self.build(card: card, page: page, media: nil)
        #expect(flight.card === card)
        #expect(flight.mediaCard === card)
        #expect(!flight.isLetterboxed)
        #expect(flight.mediaFrame == page)
        #expect(flight.cardFrame(forMedia: tile) == tile)
        #expect(flight.mediaCornerRadius(forPage: 55) == 55)
        #expect(card.frame == page)
        // The chrome rides inside the card, under its resting chrome, as ever.
        #expect(flight.chrome?.superview === card)
    }

    @Test func aMediaRectThatIsThePageBuildsTheOrdinaryFlight() {
        let card = LetterboxProbeCard()
        let flight = Self.build(card: card, page: page, media: page)
        #expect(flight.card === card)
        #expect(!flight.isLetterboxed)
    }

    // MARK: - ZoomFlight, letterboxed

    @Test func aLetterboxedFlightCarriesTheSourceCardInsideAPageShapedBox() {
        let card = LetterboxProbeCard()
        let flight = Self.build(card: card, page: page, media: media)
        #expect(flight.isLetterboxed)
        #expect(flight.card is ZoomLetterboxCard)
        #expect(flight.mediaCard === card)
        #expect(card.superview === flight.card)
        #expect(flight.card.frame == page)
        #expect(Self.near(card.frame, media))
        // The chrome reaches past the picture into the bands, so it lives in
        // the box — never clipped by the picture's card.
        #expect(flight.chrome?.superview === flight.card)
        #expect(flight.chrome?.bounds.size == page.size)
    }

    /// The live surface is laid out to cover the PICTURE's rect — which, being
    /// the picture's own aspect, it matches exactly: the page end is a fit
    /// drawn by fill math.
    @Test func theLiveSurfaceIsSizedToThePicturesRect() {
        let card = LetterboxProbeCard()
        card.nativeSize = CGSize(width: 1080, height: 1920)
        card.ownSurface = UIView()
        _ = Self.build(card: card, page: page, media: media)
        #expect(card.preparedSizes.count == 1)
        #expect(abs(card.preparedSizes[0].width - media.width) < 0.001)
        #expect(abs(card.preparedSizes[0].height - media.height) < 0.001)
    }

    @Test func thePageEndPutsThePictureOnTheFittedRectWithSquareCorners() {
        let card = LetterboxProbeCard()
        card.nativeSize = CGSize(width: 9, height: 16)
        let surface = UIView()
        card.ownSurface = surface
        let flight = Self.build(card: card, page: page, media: media)
        flight.poseAtSource()
        flight.poseAsPage(cornerRadius: 55)
        #expect(flight.card.frame == page)
        #expect(Self.near(Self.frameInContainer(card), media))
        #expect(card.appliedCornerRadii.last == 0)
        #expect(flight.chrome?.transform == .identity)
        #expect(flight.chrome?.center == CGPoint(x: page.midX, y: page.midY))
        // Fill of a same-aspect surface into the picture's rect is the identity.
        #expect(surface.transform == .identity)
        #expect(surface.center == CGPoint(x: media.width / 2, y: media.height / 2))
    }

    @Test func theSourceEndPutsThePictureExactlyOnTheTile() {
        let card = LetterboxProbeCard()
        let flight = Self.build(card: card, page: page, media: media)
        flight.poseAsPage(cornerRadius: 55)
        flight.poseAtSource()
        #expect(Self.near(Self.frameInContainer(card), tile))
        #expect(card.appliedCornerRadii.last == card.zoomRestingCornerRadius)
        #expect(Self.near(flight.card.frame, flight.cardFrame(forMedia: tile)))
        // The shadow stand-in is the TILE's, not the box's.
        #expect(flight.shadow.frame.origin == tile.origin)
        #expect(flight.chrome?.alpha == 0)
    }

    /// The grab's pose keeps the box page-shaped and the picture at the same
    /// fraction of it, so the held card is the fitted page, shrunk.
    @Test func aFloatingLetterboxIsTheFittedPageScaled() {
        let card = LetterboxProbeCard()
        let flight = Self.build(card: card, page: page, media: media)
        flight.poseFloating(scale: 0.8, cornerRadius: 44)
        #expect(Self.near(flight.card.bounds, CGRect(x: 0, y: 0, width: 402 * 0.8, height: 874 * 0.8)))
        #expect(Self.near(card.frame, CGRect(
            x: media.minX * 0.8, y: media.minY * 0.8, width: media.width * 0.8, height: media.height * 0.8
        )))
        #expect(card.appliedCornerRadii.last == 0)
    }

    /// ⚠️ NO LAYOUT PASS WRITES THE PICTURE, even when the box and the picture
    /// disagree. A frame written outside an animation block replaces the model
    /// under a property animator's additive animations and drops the position
    /// channel: a layout "backstop" that re-derived the picture from the box
    /// sent the picture to its landing centre on the first frame of a tap-back,
    /// and landed a caught-and-reversed present 45pt right and 84pt low of its
    /// tile — because UIKit re-bases the model mid-scrub, and the backstop read
    /// that as drift to fix. The disagreement is staged here directly.
    @Test func aLayoutPassNeverMovesThePicture() {
        let card = LetterboxProbeCard()
        let flight = Self.build(card: card, page: page, media: media)
        for pose in [{ flight.poseAtSource() }, { flight.poseAsPage(cornerRadius: 55) },
                     { flight.poseFloating(scale: 0.7, cornerRadius: 30) }] {
            pose()
            let skewed = card.frame.offsetBy(dx: -45, dy: -80)
            card.frame = skewed
            card.frameWrites = 0
            flight.card.setNeedsLayout()
            flight.card.layoutIfNeeded()
            #expect(card.frameWrites == 0)
            #expect(card.frame == skewed)
        }
    }

    /// The grab's dip hand-over resizes the box DIRECTLY (it adopts the
    /// presented bounds) and relies on the `poseFloating` that follows in the
    /// same turn to put the picture back in proportion.
    @Test func theFloatingPoseAfterADirectResizeRestoresProportion() {
        let card = LetterboxProbeCard()
        let flight = Self.build(card: card, page: page, media: media)
        flight.card.bounds = CGRect(x: 0, y: 0, width: 201, height: 437)
        flight.poseFloating(scale: 0.5, cornerRadius: 20)
        #expect(Self.near(card.frame, CGRect(
            x: 0, y: media.minY / 2, width: media.width / 2, height: media.height / 2
        )))
    }

    // MARK: - Helpers

    private static func build(card: LetterboxProbeCard, page: CGRect, media: CGRect?) -> ZoomFlight {
        ZoomFlight.build(
            source: LetterboxProbeSource(card: card), destination: LetterboxProbeDestination(),
            sourceFrame: CGRect(x: 8, y: 445, width: 243, height: 246),
            pageFrame: page, mediaFrame: media
        )
    }

    private static func frameInContainer(_ card: UIView) -> CGRect {
        guard let box = card.superview else { return card.frame }
        return card.frame.offsetBy(dx: box.frame.minX, dy: box.frame.minY)
    }

    private static func near(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 0.001) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }
}

// MARK: - Stage doubles

private final class LetterboxProbeSource: NSObject, ZoomTransitionSource {
    private let card: LetterboxProbeCard
    init(card: LetterboxProbeCard) { self.card = card }
    func zoomHeroFrame(in container: UICoordinateSpace) -> CGRect { .zero }
    var zoomSourceIsOnScreen: Bool { true }
    func makeZoomFlightCard() -> any ZoomFlightCard { card }
    func setZoomSourceHidden(_ hidden: Bool) {}
}

private final class LetterboxProbeDestination: NSObject, ZoomTransitionDestination {
    func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect { .zero }
    func zoomFlightChrome() -> UIView? { UIView() }
    func setZoomContentHidden(_ hidden: Bool) {}
    func zoomTransitionDidEnd() {}
    var isReadyForInteractiveDismissal: Bool { true }
    func setContentScrollEnabled(_ enabled: Bool) {}
}

private final class LetterboxProbeCard: UIView, ZoomFlightCard {
    let restingChromeView = UIView()
    var ownSurface: UIView?
    var nativeSize: CGSize?
    private(set) var preparedSizes: [CGSize] = []
    private(set) var appliedCornerRadii: [CGFloat] = []
    var frameWrites = 0

    override var frame: CGRect {
        didSet { frameWrites += 1 }
    }

    var zoomRestingCornerRadius: CGFloat { 10 }
    var zoomRestingChrome: UIView? { restingChromeView }
    func setZoomCornerRadius(_ radius: CGFloat) { appliedCornerRadii.append(radius) }
    var zoomLiveMediaSurface: UIView? { ownSurface }
    var zoomLiveMediaNativeSize: CGSize? { nativeSize }
    func prepareZoomLiveMediaForFlight(destinationSize: CGSize) {
        preparedSizes.append(destinationSize)
        ownSurface?.bounds = CGRect(origin: .zero, size: destinationSize)
    }
}
