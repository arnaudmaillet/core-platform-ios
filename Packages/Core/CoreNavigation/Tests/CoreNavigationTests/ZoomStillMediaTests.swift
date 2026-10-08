import Testing
import UIKit
@testable import CoreNavigation

/// The still picture flown at its native aspect (#539): a marker's cover and
/// baked preview, posed by transform like the live surface instead of
/// aspect-filled into the morphing card.
///
/// The failure these pin: a square crop of a 9:16 clip, re-cropped into a
/// portrait page on every frame, zoomed further and further into the face and
/// landed on a framing the page does not have.
@MainActor
struct ZoomStillMediaTests {
    private let sourceFrame = CGRect(x: 40, y: 200, width: 56, height: 56)
    private let pageFrame = CGRect(x: 0, y: 0, width: 402, height: 874)
    /// A 9:16 clip.
    private let native = CGSize(width: 720, height: 1280)

    private func flight(
        card: StillCard, framing: ZoomPageFraming? = nil
    ) -> ZoomFlight {
        ZoomFlight.build(
            source: StillSource(card: card), destination: StillDestination(framing: framing),
            sourceFrame: sourceFrame, pageFrame: pageFrame
        )
    }

    private func card() -> StillCard {
        let card = StillCard()
        card.stillNativeSize = native
        return card
    }

    /// With no live surface, the still's native aspect sizes the layout, and
    /// the still is prepared at it — once.
    @Test func theStillIsLaidOutAtItsNativeAspect() {
        let card = card()
        let built = flight(card: card)
        let cover = max(pageFrame.width / native.width, pageFrame.height / native.height)
        #expect(abs(built.liveMediaSize.width - native.width * cover) < 0.01)
        #expect(abs(built.liveMediaSize.height - native.height * cover) < 0.01)
        #expect(card.preparedStillSizes == [built.liveMediaSize])
    }

    /// Both ends are that end's own aspect-fill of the native picture: the
    /// marker's square crop at take-off, the page's crop at landing.
    @Test func bothEndsAreTheirOwnAspectFill() {
        let card = card()
        let built = flight(card: card)

        built.poseAtSource()
        let atSource = card.stillSurface.transform.a
        let markerFill = max(sourceFrame.width / built.liveMediaSize.width,
                             sourceFrame.height / built.liveMediaSize.height)
        #expect(abs(atSource - markerFill) < 0.0001)
        #expect(card.stillSurface.transform.a == card.stillSurface.transform.d, "uniform")
        #expect(card.stillSurface.center == CGPoint(x: sourceFrame.width / 2, y: sourceFrame.height / 2))

        built.poseAsPage(cornerRadius: 55)
        #expect(card.stillSurface.transform == .identity)
        #expect(card.stillSurface.center == CGPoint(x: pageFrame.width / 2, y: pageFrame.height / 2))
    }

    /// The scale only grows on the way out: no zoom in, then out again.
    @Test func theScaleIsMonotonicAcrossTheGrab() {
        let card = card()
        let built = flight(card: card)
        var last: CGFloat = .infinity
        for step in 0...20 {
            built.poseInterpolated(
                CGFloat(step) / 20, from: pageFrame.size, to: sourceFrame, startCornerRadius: 55
            )
            let scale = card.stillSurface.transform.a
            #expect(scale <= last + 0.0001, "step \(step): \(scale) after \(last)")
            last = scale
        }
    }

    /// A framed page (a landscape clip, fitted): the still covers the FITTED
    /// rect at the page end, as the live surface does.
    @Test func aFramedPageFitsTheStillLikeTheLiveSurface() throws {
        let card = StillCard()
        card.stillNativeSize = CGSize(width: 1280, height: 720)
        let framing = try #require(ZoomPageFraming(mediaAspect: CGSize(width: 16, height: 9), backdrop: .black))
        let built = flight(card: card, framing: framing)
        built.poseAsPage(cornerRadius: 55)
        let fitted = ZoomTransitionGeometry.fittedMediaSize(aspect: CGSize(width: 16, height: 9), in: pageFrame.size)
        let scale = card.stillSurface.transform.a
        #expect(abs(built.liveMediaSize.width * scale - fitted.width) < 0.5)
        #expect(abs(built.liveMediaSize.height * scale - fitted.height) < 0.5)
    }

    /// A card with no still surface is left exactly as before: nothing
    /// prepared, nothing posed.
    @Test func aCardWithoutAStillSurfaceIsUntouched() {
        let card = StillCard()
        card.hasStill = false
        _ = flight(card: card)
        #expect(card.preparedStillSizes.isEmpty)
    }
}

// MARK: - Stage doubles

private final class StillSource: NSObject, ZoomTransitionSource {
    private let card: StillCard
    init(card: StillCard) { self.card = card }
    func zoomHeroFrame(in container: UICoordinateSpace) -> CGRect { .zero }
    var zoomSourceIsOnScreen: Bool { true }
    func makeZoomFlightCard() -> any ZoomFlightCard { card }
    func setZoomSourceHidden(_ hidden: Bool) {}
}

/// Offers no live media: the still is the picture for the whole flight.
private final class StillDestination: NSObject, ZoomTransitionDestination {
    private let framing: ZoomPageFraming?
    init(framing: ZoomPageFraming?) { self.framing = framing }
    func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect { .zero }
    func zoomFlightChrome() -> UIView? { nil }
    func setZoomContentHidden(_ hidden: Bool) {}
    func zoomTransitionDidEnd() {}
    var isReadyForInteractiveDismissal: Bool { true }
    func setContentScrollEnabled(_ enabled: Bool) {}
    func zoomDonateLiveMediaView() -> UIView? { nil }
    func zoomMirrorLiveMedia(onto surface: UIView) -> Bool { false }
    func zoomPageFraming(sourcePicture: UIImage?) -> ZoomPageFraming? { framing }
}

private final class StillCard: UIView, ZoomFlightCard {
    let stillSurface = UIView()
    var hasStill = true
    var stillNativeSize: CGSize?
    private(set) var preparedStillSizes: [CGSize] = []

    var zoomRestingCornerRadius: CGFloat { 12 }
    var zoomRestingChrome: UIView? { nil }
    func setZoomCornerRadius(_ radius: CGFloat) {}

    var zoomStillMediaSurface: UIView? { hasStill ? stillSurface : nil }
    var zoomStillMediaNativeSize: CGSize? { hasStill ? stillNativeSize : nil }
    func prepareZoomStillMediaForFlight(destinationSize: CGSize) {
        preparedStillSizes.append(destinationSize)
        stillSurface.bounds = CGRect(origin: .zero, size: destinationSize)
    }
}
