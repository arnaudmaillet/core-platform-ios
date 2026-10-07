import QuartzCore
import Testing
@testable import CoreNavigation

/// The present's settlement, pinned as two phases that must not merge.
///
/// ⚠️ THE WHOLE SUITE IS ABOUT ONE LINE: which phase `completeTransition` is
/// in. It used to be in the readiness closure, so a present took as long as
/// the post took to arrive — nine presents at `-mock-latency 700` ran 577ms to
/// 3745ms. With it on the animation's clock they run 491ms to 570ms. Every
/// assertion below goes red if that line moves back.
struct ZoomPresentSettlementTests {

    /// The transition ends on the animation's clock. Not "usually", not "when
    /// the media is quick" — the readiness phase must not contain it at all.
    @Test(arguments: [true, false])
    func theTransitionCompletesOnScheduleAndNeverInTheReadinessPhase(live: Bool) {
        #expect(ZoomPresentSettlement.onSchedule().contains(.completeTransition))
        #expect(!ZoomPresentSettlement
            .whenDestinationReady(cardHasLiveSurface: live)
            .contains(.completeTransition))
    }

    /// Nothing that the VIEWER experiences as the end of the transition may be
    /// deferred to the media: the page comes out, the shield goes, the
    /// presenter is reset.
    @Test(arguments: [true, false])
    func nothingTheViewerFeelsIsDeferredToTheMedia(live: Bool) {
        let ready = ZoomPresentSettlement.whenDestinationReady(cardHasLiveSurface: live)
        for deferred in [Action.revealDestination, .dropShield, .clearFlightFurniture] {
            #expect(!ready.contains(deferred), "\(deferred) was left waiting on media")
        }
    }

    /// ⚠️ THE ORDER IS THE WHOLE OF THE COVER. The card is staged BELOW the
    /// destination, so revealing the page hides it. Parking it above must
    /// happen in the same run as the reveal, and before the transition is
    /// completed — the container is torn down at completion and takes anything
    /// still in it.
    @Test func theCardIsParkedAboveThePageBeforeUIKitIsTold() throws {
        let plan = ZoomPresentSettlement.onSchedule()
        let reveal = try #require(plan.firstIndex(of: .revealDestination))
        let park = try #require(plan.firstIndex(of: .parkCardAsCover))
        let complete = try #require(plan.firstIndex(of: .completeTransition))
        #expect(reveal < park, "the park must follow the reveal in one commit")
        #expect(park < complete, "a card still in the container is torn down with it")
    }

    /// The shield goes FIRST: it is the only thing between the viewer and the
    /// screen, and the transition is over.
    @Test func theShieldIsTheFirstThingDropped() throws {
        let plan = ZoomPresentSettlement.onSchedule()
        #expect(plan.first == .dropShield)
    }

    /// A live surface changes hands BEFORE the cover goes, or the hand-over
    /// would read a cover that is already gone — the same rule the grab's
    /// settlement states for its own card.
    @Test func theSurfaceChangesHandsBeforeTheCoverIsDropped() throws {
        let plan = ZoomPresentSettlement.whenDestinationReady(cardHasLiveSurface: true)
        let adopt = try #require(plan.firstIndex(of: .adoptSurfaceToDestination))
        let drop = try #require(plan.firstIndex(of: .dropCover))
        #expect(adopt < drop)
    }

    /// A cover-only card has nothing to hand anywhere, and still gets dropped.
    @Test func aCoverOnlyCardIsJustDropped() {
        #expect(ZoomPresentSettlement.whenDestinationReady(cardHasLiveSurface: false)
            == [.dropCover])
    }

    /// The cover is dropped exactly once, whatever the card carries: one left
    /// up is a still picture over a live page for the rest of the session.
    @Test(arguments: [true, false])
    func theCoverIsDroppedExactlyOnce(live: Bool) {
        let plan = ZoomPresentSettlement.whenDestinationReady(cardHasLiveSurface: live)
        #expect(plan.filter { $0 == .dropCover }.count == 1)
    }

    // MARK: - The cover outlives its surface's fade (#633)

    /// The late first frame: the cover's surface began fading up in the same
    /// tick the page reported rendering. Dropped then, the page took it at a
    /// presented opacity of 0.00 and showed its black floor.
    @Test func aSurfaceFadingUpHoldsTheCover() {
        #expect(ZoomPresentSettlement.liveSurfaceIsArriving(
            hasOpacityAnimation: true, shownOpacity: 0, modelOpacity: 1))
        #expect(ZoomPresentSettlement.liveSurfaceIsArriving(
            hasOpacityAnimation: true, shownOpacity: 0.6, modelOpacity: 1))
    }

    /// Done fading — the blend happened on the cover, and the drop shows nothing.
    @Test func aSurfaceUpOrNearlyUpLetsTheCoverGo() {
        #expect(!ZoomPresentSettlement.liveSurfaceIsArriving(
            hasOpacityAnimation: true, shownOpacity: 0.995, modelOpacity: 1))
        #expect(!ZoomPresentSettlement.liveSurfaceIsArriving(
            hasOpacityAnimation: false, shownOpacity: 1, modelOpacity: 1))
    }

    /// A surface with no frame sits at alpha 0 with nothing animating: it is
    /// not arriving, and holding for it would hold to the ceiling. A fade
    /// DOWN is not an arrival either.
    @Test func onlyARisingFadeHolds() {
        #expect(!ZoomPresentSettlement.liveSurfaceIsArriving(
            hasOpacityAnimation: false, shownOpacity: 0, modelOpacity: 0))
        #expect(!ZoomPresentSettlement.liveSurfaceIsArriving(
            hasOpacityAnimation: true, shownOpacity: 0.5, modelOpacity: 0))
    }

    /// Read off a real layer: no surface, or one with nothing animating, never holds.
    @Test func theLayerReading() {
        #expect(!ZoomPresentSettlement.liveSurfaceIsArriving(nil))
        #expect(!ZoomPresentSettlement.liveSurfaceIsArriving(CALayer()))
    }

    private typealias Action = ZoomPresentSettlement.Action
}
