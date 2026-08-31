import Testing
import UIKit
@testable import CoreNavigation

/// `ZoomFlight.build`'s media contract and the poses' geometry — the flying
/// unit both drivers share, pinned without a live transition.
///
/// The poses are plain view mutations (no animation is started here; the
/// drivers put them inside animation blocks), so a bare card in no window is
/// enough to assert the geometry that actually lands on screen.
@MainActor
struct ZoomFlightPoseTests {
    private let sourceFrame = CGRect(x: 40, y: 200, width: 120, height: 90)
    private let pageFrame = CGRect(x: 0, y: 0, width: 402, height: 874)

    private func flight(
        card: PoseCard = PoseCard(),
        destination: PoseDestination? = PoseDestination()
    ) -> (ZoomFlight, PoseCard, PoseDestination?) {
        let source = PoseSource(card: card)
        let built = ZoomFlight.build(
            source: source, destination: destination,
            sourceFrame: sourceFrame, pageFrame: pageFrame
        )
        return (built, card, destination)
    }

    // MARK: - build: who supplies the media, in which order

    /// Donation wins: a destination that can hand over its rendering view is
    /// never asked to mirror — a mirror is a second `AVPlayerLayer` with no
    /// decoded frame, which is the flash at the start of a flight.
    @Test func aDonatedSurfaceIsPreferredOverAMirror() {
        let (_, card, destination) = flight()
        #expect(card.adoptedViews.count == 1)
        #expect(card.adoptedViews.first === destination?.donation)
        #expect(destination?.mirrorAsked == false)
    }

    /// Mirroring is the fallback, asked exactly once, only when nothing was
    /// donated.
    @Test func mirroringIsOnlyAskedWhenNothingWasDonated() {
        let destination = PoseDestination()
        destination.donatesView = false
        let (_, card, _) = flight(destination: destination)
        #expect(card.adoptedViews.isEmpty)
        #expect(destination.mirrorAsked)
        #expect(card.mirrorOffers == 1)
    }

    /// A card that is already live is left alone — asking the destination to
    /// donate under it would fly a page nobody is looking at (the reused-feed
    /// defect this guard closed).
    @Test func aCardAlreadyLiveIsNeverOfferedAnotherSurface() {
        let card = PoseCard()
        card.ownSurface = UIView()
        let (_, _, destination) = flight(card: card)
        #expect(destination?.donateAsked == false)
        #expect(destination?.mirrorAsked == false)
        #expect(card.adoptedViews.isEmpty)
    }

    /// No donation, no mirror: the card flies its cover, and the drawing
    /// answer is `true` by definition — nothing gates on a surface that does
    /// not exist.
    @Test func aCoverOnlyCardReportsItselfDrawing() {
        let destination = PoseDestination()
        destination.donatesView = false
        destination.mirrors = false
        let (_, card, _) = flight(destination: destination)
        #expect(card.zoomLiveMediaSurface == nil)
        // The default answer, through the existential the animator holds.
        let existential: any ZoomFlightCard = card
        #expect(existential.zoomLiveMediaIsDrawing)
    }

    /// The surface is laid out at the media's NATIVE aspect, sized to just
    /// cover the page — not at the page's own size, which is already a crop.
    @Test func theLiveSurfaceIsLaidOutAtNativeAspect() {
        let card = PoseCard()
        card.nativeSize = CGSize(width: 1600, height: 900)
        let (built, _, _) = flight(card: card)
        let cover = max(pageFrame.width / 1600, pageFrame.height / 900)
        #expect(abs(built.liveMediaSize.width - 1600 * cover) < 0.01)
        #expect(abs(built.liveMediaSize.height - 900 * cover) < 0.01)
        #expect(card.preparedSizes.count == 1)
        #expect(abs((card.preparedSizes.first?.height ?? 0) - pageFrame.height) < 0.01)
    }

    /// With no native size the layout degrades to the page viewport — the
    /// previous behaviour, kept for cards that cannot answer.
    @Test func anUnknownNativeSizeFallsBackToTheViewport() {
        let (built, _, _) = flight()
        #expect(built.liveMediaSize == pageFrame.size)
    }

    // MARK: - Poses: exact endpoints

    @Test func poseAtSourceIsAnExactTwinOfTheThumbnail() {
        let (built, card, _) = flight()
        built.poseAtSource()
        #expect(card.frame == sourceFrame)
        #expect(card.appliedCornerRadii.last == card.zoomRestingCornerRadius)
        #expect(card.restingChromeView.alpha == 1)
        #expect(built.shadow.alpha == 1)
        #expect(built.chrome?.alpha == 0)
    }

    @Test func poseAsPageIsAnExactStandInForTheLandedPage() {
        let (built, card, _) = flight()
        built.poseAsPage(cornerRadius: 55)
        #expect(card.frame == pageFrame)
        #expect(card.appliedCornerRadii.last == 55)
        #expect(card.restingChromeView.alpha == 0)
        #expect(built.shadow.alpha == 0)
        #expect(built.chrome?.alpha == 1)
        #expect(built.chrome?.transform == .identity)
    }

    @Test func poseFloatingScalesThePageAboutItsOwnCentre() {
        let (built, card, _) = flight()
        built.poseFloating(scale: 0.8, cornerRadius: 30)
        #expect(abs(card.bounds.width - pageFrame.width * 0.8) < 0.01)
        #expect(abs(card.bounds.height - pageFrame.height * 0.8) < 0.01)
        #expect(built.chrome?.alpha == 1)
    }

    // MARK: - poseInterpolated: endpoints exact, path monotonic

    @Test func interpolationLandsExactlyOnBothEndpoints() {
        let (built, card, _) = flight()
        let start = CGSize(width: 380, height: 830)
        built.poseInterpolated(0, from: start, to: sourceFrame, startCornerRadius: 55)
        #expect(card.bounds.size == start)
        #expect(card.appliedCornerRadii.last == 55)
        built.poseInterpolated(1, from: start, to: sourceFrame, startCornerRadius: 55)
        #expect(card.bounds.size == sourceFrame.size)
        #expect(card.appliedCornerRadii.last == card.zoomRestingCornerRadius)
    }

    @Test func interpolationIsClampedOutsideTheUnitInterval() {
        let (built, card, _) = flight()
        let start = CGSize(width: 380, height: 830)
        built.poseInterpolated(-0.5, from: start, to: sourceFrame, startCornerRadius: 55)
        #expect(card.bounds.size == start)
        built.poseInterpolated(1.7, from: start, to: sourceFrame, startCornerRadius: 55)
        #expect(card.bounds.size == sourceFrame.size)
    }

    /// Size shrinks monotonically toward a smaller landing — a wiggle in the
    /// card's silhouette is exactly what a snap looks like on screen.
    @Test func interpolationNeverReversesAlongTheDrag() {
        let (built, card, _) = flight()
        let start = CGSize(width: 380, height: 830)
        var previousWidth = CGFloat.greatestFiniteMagnitude
        var previousHeight = CGFloat.greatestFiniteMagnitude
        for step in 0...20 {
            built.poseInterpolated(
                CGFloat(step) / 20, from: start, to: sourceFrame, startCornerRadius: 55
            )
            #expect(card.bounds.width <= previousWidth + 0.001)
            #expect(card.bounds.height <= previousHeight + 0.001)
            previousWidth = card.bounds.width
            previousHeight = card.bounds.height
        }
    }

    /// ⚠️ THE COVER PROPERTY. The interpolated surface scale is the CHORD
    /// between the two endpoint cover scales, and the needed cover at any
    /// intermediate size is a max of affine functions of `t` — convex. A
    /// chord never dips below a convex curve on its interval, so the media
    /// can never under-cover the card mid-drag. Swept across random
    /// geometries because the property, not any one flight, is the claim.
    @Test func theInterpolatedSurfaceScaleNeverUnderCoversTheCard() {
        var random = SeededRandom(seed: 0x5EED_CAFE)
        for _ in 0..<200 {
            let native = CGSize(
                width: CGFloat(random.next(in: 200...4000)),
                height: CGFloat(random.next(in: 200...4000))
            )
            let start = CGSize(
                width: CGFloat(random.next(in: 100...500)),
                height: CGFloat(random.next(in: 100...900))
            )
            let landing = CGSize(
                width: CGFloat(random.next(in: 40...400)),
                height: CGFloat(random.next(in: 40...400))
            )
            let surface = ZoomFlight.liveMediaLayoutSize(native: native, page: pageFrame.size)
            let startScale = ZoomFlight.liveMediaScale(covering: start, surface: surface)
            let endScale = ZoomFlight.liveMediaScale(covering: landing, surface: surface)
            for step in 0...10 {
                let t = CGFloat(step) / 10
                let chord = startScale + (endScale - startScale) * t
                let size = CGSize(
                    width: start.width + (landing.width - start.width) * t,
                    height: start.height + (landing.height - start.height) * t
                )
                let needed = ZoomFlight.liveMediaScale(covering: size, surface: surface)
                #expect(chord >= needed - 0.0001,
                        "under-cover at t=\(t): chord \(chord) < needed \(needed)")
            }
        }
    }
}

// MARK: - Stage doubles

private final class PoseSource: NSObject, ZoomTransitionSource {
    private let card: PoseCard
    init(card: PoseCard) { self.card = card }
    func zoomHeroFrame(in container: UICoordinateSpace) -> CGRect { .zero }
    var zoomSourceIsOnScreen: Bool { true }
    func makeZoomFlightCard() -> any ZoomFlightCard { card }
    func setZoomSourceHidden(_ hidden: Bool) {}
}

private final class PoseDestination: NSObject, ZoomTransitionDestination {
    let donation = UIView()
    var donatesView = true
    var mirrors = true
    private(set) var donateAsked = false
    private(set) var mirrorAsked = false

    func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect { .zero }
    func zoomFlightChrome() -> UIView? { UIView() }
    func setZoomContentHidden(_ hidden: Bool) {}
    func zoomTransitionDidEnd() {}
    var isReadyForInteractiveDismissal: Bool { true }
    func setContentScrollEnabled(_ enabled: Bool) {}

    func zoomDonateLiveMediaView() -> UIView? {
        donateAsked = true
        return donatesView ? donation : nil
    }

    func zoomMirrorLiveMedia(onto surface: UIView) -> Bool {
        mirrorAsked = true
        return mirrors
    }
}

private final class PoseCard: UIView, ZoomFlightCard {
    let restingChromeView = UIView()
    var ownSurface: UIView?
    var nativeSize: CGSize?
    private(set) var adoptedViews: [UIView] = []
    private(set) var mirrorOffers = 0
    private(set) var preparedSizes: [CGSize] = []
    private(set) var appliedCornerRadii: [CGFloat] = []

    var zoomRestingCornerRadius: CGFloat { 10 }
    var zoomRestingChrome: UIView? { restingChromeView }
    func setZoomCornerRadius(_ radius: CGFloat) { appliedCornerRadii.append(radius) }

    var zoomLiveMediaSurface: UIView? { ownSurface }
    var zoomLiveMediaNativeSize: CGSize? { nativeSize }

    func adoptZoomLiveMediaView(_ view: UIView) {
        adoptedViews.append(view)
        ownSurface = view
        addSubview(view)
    }

    func adoptZoomLiveMedia(_ mirror: (UIView) -> Bool) {
        mirrorOffers += 1
        let surface = UIView()
        if mirror(surface) {
            ownSurface = surface
            addSubview(surface)
        }
    }

    func prepareZoomLiveMediaForFlight(destinationSize: CGSize) {
        preparedSizes.append(destinationSize)
    }
}

/// Deterministic RNG for property sweeps — `Date`/`SystemRandom` seeds would
/// make a red run unreproducible.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func next(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
    }

    mutating func nextUnit() -> Double {
        Double(next() % 1_000_000) / 1_000_000
    }
}
