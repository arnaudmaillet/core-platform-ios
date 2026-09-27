import Testing
import UIKit
@testable import CoreNavigation

/// The page-window hero: a destination that FITS its picture
/// (`zoomPageFraming`) gets a flight whose moving unit is a page-shaped window
/// — the tile's rect at one end, the page's at the other — with the page's
/// backdrop in it and the source's card as the picture; a destination that
/// says nothing gets exactly the flight it always had.
///
/// Geometry first (pure), then `ZoomFlight` built both ways and posed at both
/// ends. The poses are plain view mutations, so a card in no window is enough
/// to assert where each piece lands.
@MainActor
struct ZoomPageWindowTests {
    private let page = CGRect(x: 0, y: 0, width: 402, height: 874)
    private let tile = CGRect(x: 8, y: 445, width: 180, height: 240)
    /// A 4:5 photo: full width on the page, bands above and below.
    private let aspect = CGSize(width: 4, height: 5)

    // MARK: - Geometry

    @Test func aPortraitPictureFillsTheWidthAndIsCentred() {
        let size = ZoomTransitionGeometry.fittedMediaSize(aspect: CGSize(width: 1080, height: 1440), in: page.size)
        #expect(abs(size.width - 402) < 0.001)
        #expect(abs(size.height - 536) < 0.001)
    }

    @Test func aDegenerateAspectFitsAsTheWholeArea() {
        #expect(ZoomTransitionGeometry.fittedMediaSize(aspect: .zero, in: page.size) == page.size)
    }

    /// Fit 0 is the tile end — the picture COVERS the window, which is the
    /// tile's own aspect-fill crop; fit 1 is the page end — fitted, centred.
    @Test func thePictureRunsFromCoveringTheWindowToFittedInIt() {
        let covering = ZoomTransitionGeometry.pageWindowMediaRect(window: tile.size, aspect: aspect, fit: 0)
        #expect(covering == CGRect(origin: .zero, size: tile.size))
        let fitted = ZoomTransitionGeometry.pageWindowMediaRect(window: page.size, aspect: aspect, fit: 1)
        #expect(Self.near(fitted, CGRect(x: 0, y: (874 - 502.5) / 2, width: 402, height: 502.5)))
        // Halfway is the linear blend, centred — what an animator draws.
        let half = ZoomTransitionGeometry.pageWindowMediaRect(window: page.size, aspect: aspect, fit: 0.5)
        #expect(abs(half.height - (874 + 502.5) / 2) < 0.001)
        #expect(abs(half.midY - 437) < 0.001)
    }

    /// The grab's interpolation starts from the FITTED picture in the detached
    /// page and ends on the WHOLE landing tile, and it is centred in the
    /// window's current size at every step.
    @Test func theGrabsInterpolationRunsFromFittedToTheWholeTile() {
        let detached = CGSize(width: 402 * 0.8, height: 874 * 0.8)
        let start = ZoomTransitionGeometry.interpolatedWindowMediaRect(
            from: detached, to: tile.size, aspect: aspect, progress: 0
        )
        #expect(Self.near(start.size, ZoomTransitionGeometry.fittedMediaSize(aspect: aspect, in: detached)))
        let end = ZoomTransitionGeometry.interpolatedWindowMediaRect(
            from: detached, to: tile.size, aspect: aspect, progress: 1
        )
        #expect(Self.near(end, CGRect(origin: .zero, size: tile.size)))
        let mid = ZoomTransitionGeometry.interpolatedWindowMediaRect(
            from: detached, to: tile.size, aspect: aspect, progress: 0.5
        )
        let window = CGSize(width: (detached.width + tile.width) / 2, height: (detached.height + tile.height) / 2)
        #expect(abs(mid.midX - window.width / 2) < 0.001)
        #expect(abs(mid.midY - window.height / 2) < 0.001)
        // Inside the window at every step: the window clips, and a picture
        // that overhung it would be cropped by something other than the pose.
        #expect(mid.width <= window.width + 0.001 && mid.height <= window.height + 0.001)
    }

    // MARK: - Built without framing: nothing changes

    @Test func aFillingPageFliesTheSourcesOwnCard() {
        let card = WindowProbeCard()
        let flight = Self.build(card: card, framing: nil, page: page, tile: tile)
        #expect(flight.card === card)
        #expect(flight.mediaCard === card)
        #expect(!flight.isFramed)
        #expect(flight.mediaFrame == page)
        flight.poseAsPage(cornerRadius: 55)
        #expect(card.frame == page)
        #expect(card.appliedCornerRadii.last == 55)
    }

    // MARK: - Built with framing: the page window

    @Test func aFittingPageFliesAPageWindowAroundTheCard() throws {
        let card = WindowProbeCard()
        let backdrop = UIImage()
        let framing = try #require(ZoomPageFraming(mediaAspect: aspect, backdrop: .picture(backdrop)))
        let flight = Self.build(card: card, framing: framing, page: page, tile: tile)
        let window = try #require(flight.card as? ZoomPageWindowCard)
        #expect(flight.mediaCard === card)
        #expect(card.superview === window)
        #expect(window.clipsToBounds)
        #expect(window.backdropView.image === backdrop)
        #expect(Self.near(flight.mediaFrame, CGRect(x: 0, y: (874 - 502.5) / 2, width: 402, height: 502.5)))
    }

    @Test func aBlackBackdropIsBlack() throws {
        let framing = try #require(ZoomPageFraming(mediaAspect: CGSize(width: 16, height: 9), backdrop: .black))
        let flight = Self.build(card: WindowProbeCard(), framing: framing, page: page, tile: tile)
        let window = try #require(flight.card as? ZoomPageWindowCard)
        #expect(window.backdropView.image == nil)
        #expect(window.backgroundColor == .black)
    }

    /// At the tile end the WINDOW is the tile and the picture is the whole
    /// window, at the tile's own corner: pixel for pixel the tile.
    @Test func atTheSourceTheWindowIsTheTileAndThePictureIsAllOfIt() throws {
        let card = WindowProbeCard()
        let flight = try Self.framed(card: card, page: page, tile: tile, aspect: aspect)
        flight.poseAtSource()
        #expect(flight.card.frame == tile)
        #expect(card.frame == CGRect(origin: .zero, size: tile.size))
        #expect(flight.card.layer.cornerRadius == 10)
        #expect(card.appliedCornerRadii.last == 10)
    }

    /// At the page end the WINDOW is the page at the display's corner, and the
    /// picture is fitted in it, square-cornered — the page's composition.
    @Test func atThePageTheWindowIsThePageAndThePictureIsFitted() throws {
        let card = WindowProbeCard()
        let flight = try Self.framed(card: card, page: page, tile: tile, aspect: aspect)
        flight.poseAtSource()
        flight.poseAsPage(cornerRadius: 55)
        #expect(flight.card.frame == page)
        #expect(flight.card.layer.cornerRadius == 55)
        #expect(Self.near(card.frame, CGRect(x: 0, y: (874 - 502.5) / 2, width: 402, height: 502.5)))
        #expect(card.appliedCornerRadii.last == 0)
    }

    /// A held page window is still the page: the picture stays fitted, scaled
    /// with the window.
    @Test func aFloatingWindowKeepsItsPictureFitted() throws {
        let card = WindowProbeCard()
        let flight = try Self.framed(card: card, page: page, tile: tile, aspect: aspect)
        flight.poseFloating(scale: 0.5, cornerRadius: 30)
        #expect(Self.near(flight.card.bounds.size, CGSize(width: 201, height: 437)))
        #expect(Self.near(card.frame, CGRect(x: 0, y: (437 - 251.25) / 2, width: 201, height: 251.25)))
    }

    @Test func theInterpolatedPoseLandsOnTheWholeTile() throws {
        let card = WindowProbeCard()
        let flight = try Self.framed(card: card, page: page, tile: tile, aspect: aspect)
        flight.poseInterpolated(1, from: page.size, to: tile, startCornerRadius: 55)
        #expect(card.frame == CGRect(origin: .zero, size: tile.size))
        #expect(card.appliedCornerRadii.last == 10)
        flight.poseInterpolated(0, from: page.size, to: tile, startCornerRadius: 55)
        #expect(Self.near(card.frame, CGRect(x: 0, y: (874 - 502.5) / 2, width: 402, height: 502.5)))
        #expect(card.appliedCornerRadii.last == 0)
    }

    /// The live surface covers the PICTURE's rect at both ends — the fitted
    /// rect on the page (scale ~1, it was laid out to cover exactly that), the
    /// tile at the source.
    @Test func theLiveSurfaceCoversThePicturesRectAtBothEnds() throws {
        let card = WindowProbeCard()
        let surface = UIView()
        card.addSubview(surface)
        card.ownSurface = surface
        card.nativeSize = CGSize(width: 1080, height: 1350)
        let flight = try Self.framed(card: card, page: page, tile: tile, aspect: aspect)
        #expect(Self.near(flight.liveMediaSize, CGSize(width: 402, height: 502.5)))
        flight.poseAsPage(cornerRadius: 55)
        #expect(abs(surface.transform.a - 1) < 0.001)
        #expect(Self.near(surface.center, CGPoint(x: 201, y: 251.25)))
        flight.poseAtSource()
        let cover = max(tile.width / 402, tile.height / 502.5)
        #expect(abs(surface.transform.a - cover) < 0.001)
        #expect(Self.near(surface.center, CGPoint(x: tile.width / 2, y: tile.height / 2)))
    }

    /// The window rounds itself; every other member is the picture's answer.
    @Test func theWindowForwardsEverythingButItsCorner() throws {
        let card = WindowProbeCard()
        let flight = try Self.framed(card: card, page: page, tile: tile, aspect: aspect)
        let before = card.appliedCornerRadii.count
        flight.card.setZoomCornerRadius(20)
        #expect(flight.card.layer.cornerRadius == 20)
        #expect(card.appliedCornerRadii.count == before)
        #expect(flight.card.zoomRestingCornerRadius == 10)
        #expect(flight.card.zoomRestingChrome === card.restingChromeView)
    }

    /// ⚠️ No layout pass places the picture — the lesson #255 paid for twice:
    /// a frame written outside the animation block under a running property
    /// animator dropped the position channel, and the picture jumped.
    @Test func noLayoutPassMovesThePicture() throws {
        let card = WindowProbeCard()
        let flight = try Self.framed(card: card, page: page, tile: tile, aspect: aspect)
        flight.poseAsPage(cornerRadius: 55)
        let skewed = card.frame.offsetBy(dx: -45, dy: -80)
        card.frame = skewed
        flight.card.setNeedsLayout()
        flight.card.layoutIfNeeded()
        #expect(card.frame == skewed)
    }

    // MARK: - Helpers

    private static func framed(
        card: WindowProbeCard, page: CGRect, tile: CGRect, aspect: CGSize
    ) throws -> ZoomFlight {
        let framing = try #require(ZoomPageFraming(mediaAspect: aspect, backdrop: .black))
        return build(card: card, framing: framing, page: page, tile: tile)
    }

    private static func build(
        card: WindowProbeCard, framing: ZoomPageFraming?, page: CGRect, tile: CGRect
    ) -> ZoomFlight {
        ZoomFlight.build(
            source: WindowProbeSource(card: card),
            destination: WindowProbeDestination(framing: framing),
            sourceFrame: tile, pageFrame: page
        )
    }

    private static func near(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 0.001) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }

    private static func near(_ a: CGSize, _ b: CGSize, _ tolerance: CGFloat = 0.001) -> Bool {
        abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }

    private static func near(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 0.001) -> Bool {
        abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
    }
}

// MARK: - Stage doubles

private final class WindowProbeSource: NSObject, ZoomTransitionSource {
    private let card: WindowProbeCard
    init(card: WindowProbeCard) { self.card = card }
    func zoomHeroFrame(in container: UICoordinateSpace) -> CGRect { .zero }
    var zoomSourceIsOnScreen: Bool { true }
    func makeZoomFlightCard() -> any ZoomFlightCard { card }
    func setZoomSourceHidden(_ hidden: Bool) {}
}

private final class WindowProbeDestination: NSObject, ZoomTransitionDestination {
    let framing: ZoomPageFraming?
    init(framing: ZoomPageFraming?) { self.framing = framing }
    func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect { .zero }
    func zoomPageFraming(sourcePicture: UIImage?) -> ZoomPageFraming? { framing }
    func zoomFlightChrome() -> UIView? { UIView() }
    func setZoomContentHidden(_ hidden: Bool) {}
    func zoomTransitionDidEnd() {}
    var isReadyForInteractiveDismissal: Bool { true }
    func setContentScrollEnabled(_ enabled: Bool) {}
}

private final class WindowProbeCard: UIView, ZoomFlightCard {
    let restingChromeView = UIView()
    var ownSurface: UIView?
    var nativeSize: CGSize?
    private(set) var appliedCornerRadii: [CGFloat] = []

    var zoomRestingCornerRadius: CGFloat { 10 }
    var zoomRestingChrome: UIView? { restingChromeView }
    func setZoomCornerRadius(_ radius: CGFloat) { appliedCornerRadii.append(radius) }
    var zoomLiveMediaSurface: UIView? { ownSurface }
    var zoomLiveMediaNativeSize: CGSize? { nativeSize }
    func prepareZoomLiveMediaForFlight(destinationSize: CGSize) {
        ownSurface?.bounds = CGRect(origin: .zero, size: destinationSize)
    }
}
