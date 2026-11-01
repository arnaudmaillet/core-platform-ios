import Testing
import UIKit
@testable import CoreNavigation

/// ⚠️ THE ARRIVING PICTURE RIDES THE CARD FROM TAKE-OFF (#2033): on a present
/// that flies no player (a map marker, a friend's face), the surface the
/// page's player will be mirrored onto is posed with the card from the first
/// frame, and only its contents arrive mid-flight.
///
/// The failure these pin, filmed on the owner's device: the picture adopted
/// mid-flight was posed by an animation ADDED to the running animator, which
/// starts the curve again from rest — a picture smaller than its window,
/// pinned to its top-left corner, until both settled.
@MainActor
struct ZoomReservedLiveMediaTests {
    private let sourceFrame = CGRect(x: 40, y: 200, width: 56, height: 56)
    private let pageFrame = CGRect(x: 0, y: 0, width: 402, height: 874)

    private func flight(_ card: ReservingCard, page: ReservingPage = ReservingPage(), presents: Bool = true) -> ZoomFlight {
        ZoomFlight.build(
            source: ReservingSource(card: card), destination: page,
            sourceFrame: sourceFrame, pageFrame: pageFrame, presents: presents
        )
    }

    /// Laid out at the flight's size, with the still, and posed with it at
    /// both ends.
    @Test func theReservedSurfaceIsPosedFromTakeOff() {
        let card = ReservingCard()
        let built = flight(card)
        #expect(built.reservedLiveMediaSurface === card.reserved)
        #expect(card.preparedLiveSizes == [built.liveMediaSize])
        built.poseAtSource()
        #expect(card.reserved.transform == card.still.transform)
        #expect(card.reserved.center == card.still.center)
        built.poseAsPage(cornerRadius: 55)
        #expect(card.reserved.transform == card.still.transform)
        #expect(card.reserved.center == card.still.center)
    }

    /// A dismissal mirrors nothing: nothing is reserved.
    @Test func aDismissalReservesNothing() {
        let card = ReservingCard()
        let built = flight(card, presents: false)
        #expect(built.reservedLiveMediaSurface == nil)
        #expect(card.preparedLiveSizes.isEmpty)
    }

    /// A caught or scrubbed present carries it with the card, as the still.
    @Test func aCaughtPresentCarriesIt() {
        let card = ReservingCard()
        let built = flight(card)
        for t in stride(from: 0.0, through: 1.0, by: 0.25) {
            built.poseInterpolated(CGFloat(t), from: pageFrame.size, to: sourceFrame, startCornerRadius: 55)
            #expect(card.reserved.transform == card.still.transform, "t=\(t)")
            #expect(card.reserved.center == card.still.center, "t=\(t)")
        }
        built.poseFloating(scale: 0.7, cornerRadius: 30)
        #expect(card.reserved.transform == card.still.transform)
    }

    /// The retry fills the posed surface and writes no geometry: not laid
    /// out again, not posed, not held — faded up over what is left.
    @Test func theRetryFillsThePosedSurfaceOnly() {
        let card = ReservingCard()
        let window = UIWindow(frame: pageFrame)
        window.addSubview(card)
        window.isHidden = false
        let page = ReservingPage()
        let built = flight(card, page: page)
        built.poseAsPage(cornerRadius: 55)
        let posed = (card.reserved.transform, card.reserved.center, card.preparedLiveSizes)
        page.isPlaying = true
        let retry = ZoomLiveMediaRetry.arm(
            card: card, pageSize: built.mediaFrame.size, mirroring: page,
            posed: built.reservedLiveMediaSurface, window: 600
        )
        retry?.debugTick()
        #expect(card.zoomLiveMediaSurface === card.reserved, "the page's player never reached the card")
        #expect(card.reserved.transform == posed.0 && card.reserved.center == posed.1, "the retry posed it")
        #expect(card.preparedLiveSizes == posed.2, "the retry laid it out again")
        #expect(!card.isHoldingArrival, "held back from a window that carries it")
        #expect((card.fadeDuration ?? 0) >= 0.2, "it cut in instead of fading up")
        retry?.debugTick()
        #expect(card.reserved.transform == posed.0, "the follow posed it a frame behind")
        retry?.debugFinish()
        window.isHidden = true
    }

    /// ⚠️ THE SAME CURVE: adopted part-way through a running present, the
    /// surface presents the same scale and centre as the still posed from
    /// take-off, at every instant sampled after the adoption.
    @Test func anAdoptedSurfaceRidesTheCardsCurve() async throws {
        let card = ReservingCard()
        let window = UIWindow(frame: pageFrame)
        window.addSubview(card)
        window.isHidden = false
        let page = ReservingPage()
        let built = flight(card, page: page)
        built.poseAtSource()
        let animator = UIViewPropertyAnimator(
            duration: 0.8, timingParameters: UISpringTimingParameters(dampingRatio: ZoomFlight.springDamping)
        )
        animator.addAnimations { built.poseAsPage(cornerRadius: 55) }
        animator.startAnimation()
        try await Task.sleep(for: .milliseconds(120))
        page.isPlaying = true
        let retry = ZoomLiveMediaRetry.arm(
            card: card, pageSize: built.mediaFrame.size, mirroring: page,
            posed: built.reservedLiveMediaSurface, window: 600
        )
        retry?.debugTick()
        #expect(card.zoomLiveMediaSurface === card.reserved)
        var sampled = 0
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(60))
            guard let still = card.still.layer.presentation(), let reserved = card.reserved.layer.presentation()
            else { continue }
            sampled += 1
            let scales = (still.transform.m11, reserved.transform.m11)
            #expect(abs(scales.0 - scales.1) < 0.0001, "scale \(scales.1) against the still's \(scales.0)")
            #expect(abs(still.position.x - reserved.position.x) < 0.01 && abs(still.position.y - reserved.position.y) < 0.01,
                    "centre \(reserved.position) against the still's \(still.position)")
        }
        #expect(sampled > 0, "nothing was sampled")
        animator.stopAnimation(true)
        retry?.debugFinish()
        window.isHidden = true
    }
}

private final class ReservingSource: NSObject, ZoomTransitionSource {
    private let card: ReservingCard
    init(card: ReservingCard) { self.card = card }
    func zoomHeroFrame(in container: UICoordinateSpace) -> CGRect { .zero }
    var zoomSourceIsOnScreen: Bool { true }
    var zoomFlightCarriesLivePlayer: Bool { false }
    func makeZoomFlightCard() -> any ZoomFlightCard { card }
    func setZoomSourceHidden(_ hidden: Bool) {}
}

/// A page whose player starts mid-flight.
private final class ReservingPage: NSObject, ZoomTransitionDestination {
    var isPlaying = false
    func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect { .zero }
    func zoomFlightChrome() -> UIView? { nil }
    func setZoomContentHidden(_ hidden: Bool) {}
    func zoomTransitionDidEnd() {}
    var isReadyForInteractiveDismissal: Bool { true }
    func setContentScrollEnabled(_ enabled: Bool) {}
    func zoomDonateLiveMediaView() -> UIView? { nil }
    func zoomMirrorLiveMedia(onto surface: UIView) -> Bool { isPlaying }
}

/// A marker's card: a still at its native aspect, and its own render view
/// reserved while it carries nothing.
private final class ReservingCard: UIView, ZoomFlightCard {
    let still = UIView()
    let reserved = UIView()
    private var isLive = false
    private(set) var preparedLiveSizes: [CGSize] = []
    private(set) var fadeDuration: TimeInterval?
    private(set) var isHoldingArrival = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(still)
        addSubview(reserved)
        reserved.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var zoomRestingCornerRadius: CGFloat { 12 }
    var zoomRestingChrome: UIView? { nil }
    func setZoomCornerRadius(_ radius: CGFloat) {}

    var zoomStillMediaSurface: UIView? { still }
    var zoomStillMediaNativeSize: CGSize? { CGSize(width: 720, height: 1280) }
    func prepareZoomStillMediaForFlight(destinationSize: CGSize) {
        still.bounds = CGRect(origin: .zero, size: destinationSize)
    }

    var zoomLiveMediaSurface: UIView? { isLive ? reserved : nil }
    var zoomReservedLiveMediaSurface: UIView? { isLive ? nil : reserved }
    func prepareZoomLiveMediaForFlight(destinationSize: CGSize) {
        preparedLiveSizes.append(destinationSize)
        reserved.transform = .identity
        reserved.bounds = CGRect(origin: .zero, size: destinationSize)
    }
    func adoptZoomLiveMedia(_ mirror: (UIView) -> Bool) {
        guard mirror(reserved) else { return }
        reserved.isHidden = false
        isLive = true
    }
    func fadeInAdoptedLiveMedia(over duration: TimeInterval) { fadeDuration = duration }
    func holdAdoptedLiveMediaUntilLanding() { isHoldingArrival = true }
}
