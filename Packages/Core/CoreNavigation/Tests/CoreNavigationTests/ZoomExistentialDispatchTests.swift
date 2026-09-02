import Testing
import UIKit
@testable import CoreNavigation

/// Every defaulted member of the three hero protocols, observed THROUGH the
/// existential a conformer is actually held as.
///
/// ⚠️ Why this suite exists: a protocol-extension method with no requirement
/// behind it dispatches STATICALLY — every conformer's override is invisible
/// through `any P` and the default is the only answer anyone ever gets. That
/// exact trap shipped once: `zoomLiveMediaSurfaceIfReady` was an extension
/// member, the mid-flight retry held `any ZoomTransitionSource`, and the
/// grid's override was never called — the retry ran, reported itself asking,
/// and adopted nothing, indistinguishable from "no player was ready".
///
/// The machinery holds BOTH sides as existentials everywhere (`ZoomAnimator`,
/// the grab driver, `ZoomLiveMediaRetry`, `ZoomFlight.build`), so every
/// member here must stay a REQUIREMENT declared in the protocol body. Adding
/// a defaulted extension member without its requirement will not fail this
/// suite by name — add the new member to the spy below when you add it to the
/// protocol; that is the maintenance contract this file buys.
@MainActor
struct ZoomExistentialDispatchTests {
    // MARK: - Source (9 defaulted members)

    @Test func everyDefaultedSourceMemberDispatchesDynamically() {
        let spy = SpySource()
        let source: any ZoomTransitionSource = spy
        let probe = UIView()

        #expect(source.zoomLiveMediaSurfaceIfReady() === spy.readySurface)
        #expect(source.zoomPresenterDepthView === spy.depthView)
        source.zoomSourceWillStageDismissal()
        source.zoomAdoptLiveMediaView(probe)
        #expect(source.zoomLandingMediaIsReady == false)
        source.zoomFinalizeLanding()
        #expect(source.zoomHoistLiveMedia(probe, at: .zero, in: UIView(), cornerRadius: 5))
        source.zoomPoseHoistedMedia(at: .zero, in: UIView(), cornerRadius: 5)
        #expect(source.zoomReleaseHoistedMedia() === spy.hoistedRelease)

        #expect(spy.calls == [
            "surfaceIfReady", "depthView", "willStageDismissal", "adopt",
            "landingReady", "finalizeLanding", "hoist", "poseHoisted", "releaseHoisted",
        ])
    }

    // MARK: - Destination (14 defaulted members)

    @Test func everyDefaultedDestinationMemberDispatchesDynamically() {
        let spy = SpyDestination()
        let destination: any ZoomTransitionDestination = spy
        let probe = UIView()

        #expect(destination.zoomDismissalKind == .card)
        #expect(destination.zoomDestinationContentIsReady == false)
        #expect(destination.zoomOwnsInteractiveDismissal == false)
        #expect(destination.concealsAppTabBar == false)
        #expect(destination.zoomDestinationMediaIsRendering == false)
        #expect(destination.zoomVerticalDismissalPermitted(at: .zero, in: probe) == false)
        #expect(destination.zoomHorizontalDismissalPermitted(at: .zero, in: probe) == false)
        #expect(destination.zoomMirrorLiveMedia(onto: probe))
        #expect(destination.zoomDonateLiveMediaView() === spy.donation)
        destination.zoomReclaimLiveMediaView(probe)
        destination.zoomAdoptLiveMediaView(probe)
        destination.zoomTransitionWillBegin()
        destination.setZoomDismissState(ZoomDismissState(
            progress: 0.5, card: .zero, cornerRadius: 1, isSettling: false
        ))
        #expect(destination.zoomParkLiveMediaForHandoff())

        #expect(spy.calls == [
            "kind", "contentReady", "ownsDismissal", "concealsTabBar", "mediaRendering",
            "verticalPermitted", "horizontalPermitted", "mirror", "donate",
            "reclaim", "adopt", "willBegin", "dismissState", "park",
        ])
    }

    // MARK: - Flight card (11 defaulted members)

    @Test func everyDefaultedFlightCardMemberDispatchesDynamically() {
        let spy = SpyCard()
        let card: any ZoomFlightCard = spy
        let probe = UIView()

        #expect(card.zoomLiveMediaIsDrawing == false)
        #expect(card.zoomLiveMediaDebugState == "spy-state")
        #expect(card.zoomLiveMediaNativeSize == CGSize(width: 16, height: 9))
        #expect(card.zoomLiveMediaSurface === spy.surface)
        card.adoptZoomLiveMedia { _ in true }
        card.adoptZoomLiveMediaView(probe)
        #expect(card.zoomLiveMediaTracksCardBounds)
        card.setZoomContentBlend(0.5)
        card.setZoomLandingLiveMedia(probe)
        card.prepareZoomLiveMediaForFlight(destinationSize: CGSize(width: 3, height: 4))
        card.applyZoomRestingShadow(to: CALayer())

        #expect(spy.calls == [
            "isDrawing", "debugState", "nativeSize", "surface", "adoptMirror",
            "adoptView", "tracksBounds", "blend", "landingLive", "prepare", "applyShadow",
        ])
    }
}

// MARK: - Spies (override EVERY defaulted member with a non-default answer)

private final class SpySource: NSObject, ZoomTransitionSource {
    private(set) var calls: [String] = []
    let readySurface = UIView()
    let depthView = UIView()
    let hoistedRelease = UIView()

    // Required members.
    func zoomHeroFrame(in container: UICoordinateSpace) -> CGRect { .zero }
    var zoomSourceIsOnScreen: Bool { true }
    func makeZoomFlightCard() -> any ZoomFlightCard { SpyCard() }
    func setZoomSourceHidden(_ hidden: Bool) {}

    // Defaulted members, all overridden with observable answers.
    func zoomLiveMediaSurfaceIfReady() -> UIView? { calls.append("surfaceIfReady"); return readySurface }
    var zoomPresenterDepthView: UIView? { calls.append("depthView"); return depthView }
    func zoomSourceWillStageDismissal() { calls.append("willStageDismissal") }
    func zoomAdoptLiveMediaView(_ view: UIView) { calls.append("adopt") }
    var zoomLandingMediaIsReady: Bool { calls.append("landingReady"); return false }
    func zoomFinalizeLanding() { calls.append("finalizeLanding") }
    func zoomHoistLiveMedia(
        _ view: UIView, at rect: CGRect, in space: UICoordinateSpace, cornerRadius: CGFloat
    ) -> Bool { calls.append("hoist"); return true }
    func zoomPoseHoistedMedia(at rect: CGRect, in space: UICoordinateSpace, cornerRadius: CGFloat) {
        calls.append("poseHoisted")
    }
    func zoomReleaseHoistedMedia() -> UIView? { calls.append("releaseHoisted"); return hoistedRelease }
}

private final class SpyDestination: NSObject, ZoomTransitionDestination {
    private(set) var calls: [String] = []
    let donation = UIView()

    // Required members.
    func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect { .zero }
    func zoomFlightChrome() -> UIView? { nil }
    func setZoomContentHidden(_ hidden: Bool) {}
    func zoomTransitionDidEnd() {}
    var isReadyForInteractiveDismissal: Bool { true }
    func setContentScrollEnabled(_ enabled: Bool) {}

    // Defaulted members, all overridden with observable answers.
    var zoomDismissalKind: ZoomDismissalKind { calls.append("kind"); return .card }
    var zoomDestinationContentIsReady: Bool { calls.append("contentReady"); return false }
    var zoomOwnsInteractiveDismissal: Bool { calls.append("ownsDismissal"); return false }
    var concealsAppTabBar: Bool { calls.append("concealsTabBar"); return false }
    var zoomDestinationMediaIsRendering: Bool { calls.append("mediaRendering"); return false }
    func zoomVerticalDismissalPermitted(at location: CGPoint, in view: UIView) -> Bool {
        calls.append("verticalPermitted"); return false
    }
    func zoomHorizontalDismissalPermitted(at location: CGPoint, in view: UIView) -> Bool {
        calls.append("horizontalPermitted"); return false
    }
    func zoomMirrorLiveMedia(onto surface: UIView) -> Bool { calls.append("mirror"); return true }
    func zoomDonateLiveMediaView() -> UIView? { calls.append("donate"); return donation }
    func zoomReclaimLiveMediaView(_ view: UIView) { calls.append("reclaim") }
    func zoomAdoptLiveMediaView(_ view: UIView) { calls.append("adopt") }
    func zoomTransitionWillBegin() { calls.append("willBegin") }
    func setZoomDismissState(_ state: ZoomDismissState) { calls.append("dismissState") }
    func zoomParkLiveMediaForHandoff() -> Bool { calls.append("park"); return true }
}

private final class SpyCard: UIView, ZoomFlightCard {
    private(set) var calls: [String] = []
    let surface = UIView()

    // Required members.
    var zoomRestingCornerRadius: CGFloat { 10 }
    var zoomRestingChrome: UIView? { nil }
    func setZoomCornerRadius(_ radius: CGFloat) {}

    // Defaulted members, all overridden with observable answers.
    var zoomLiveMediaIsDrawing: Bool { calls.append("isDrawing"); return false }
    var zoomLiveMediaDebugState: String { calls.append("debugState"); return "spy-state" }
    var zoomLiveMediaNativeSize: CGSize? { calls.append("nativeSize"); return CGSize(width: 16, height: 9) }
    var zoomLiveMediaSurface: UIView? { calls.append("surface"); return surface }
    func adoptZoomLiveMedia(_ mirror: (UIView) -> Bool) { calls.append("adoptMirror") }
    func adoptZoomLiveMediaView(_ view: UIView) { calls.append("adoptView") }
    var zoomLiveMediaTracksCardBounds: Bool { calls.append("tracksBounds"); return true }
    func setZoomContentBlend(_ t: CGFloat) { calls.append("blend") }
    func setZoomLandingLiveMedia(_ view: UIView) { calls.append("landingLive") }
    func prepareZoomLiveMediaForFlight(destinationSize: CGSize) { calls.append("prepare") }
    func applyZoomRestingShadow(to layer: CALayer) { calls.append("applyShadow") }
}
