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

    private typealias Action = ZoomPresentSettlement.Action
}
