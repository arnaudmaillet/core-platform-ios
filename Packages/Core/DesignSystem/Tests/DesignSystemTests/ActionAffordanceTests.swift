import Testing
import UIKit
@testable import DesignSystem

/// The card actions' one component: a tap, a hold, a wash, a menu.
@MainActor
struct ActionAffordanceTests {
    private func chip() -> UIView {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 80, height: 32))
        host.isUserInteractionEnabled = false
        return host
    }

    @Test func aTapFiresTheAction() {
        var fired = 0
        let view = chip()
        let affordance = ActionAffordance.attach(to: view) { fired += 1 }

        affordance.debugTap()

        #expect(fired == 1)
        // A view that was furniture becomes a control, and says so.
        #expect(view.isUserInteractionEnabled)
        #expect(view.accessibilityTraits.contains(.button))
    }

    /// ⚠️ A held chip lifted INSIDE is still a press; lifted outside it is a
    /// change of mind — and never both a tap and a hold.
    @Test func aHoldFiresOnceOnlyWhenLiftedInside() {
        var fired = 0
        let affordance = ActionAffordance.attach(to: chip()) { fired += 1 }

        affordance.debugHold(liftInside: true)
        #expect(fired == 1)

        affordance.debugHold(liftInside: false)
        #expect(fired == 1)
        #expect(affordance.isHeld == false)
    }

    /// The tap waits for the hold to fail, so a quick lift is the tap's and a
    /// long one the hold's: the action cannot fire twice for one finger.
    @Test func theTapWaitsForTheHold() {
        let affordance = ActionAffordance.attach(to: chip())
        let hold = affordance.debugHoldRecognizer
        #expect(hold.minimumPressDuration == ActionAffordance.Metrics.holdDuration)
        // A lift after a hold must never also select the row under the chip.
        #expect(hold.cancelsTouchesInView)
        #expect(affordance.debugTapRecognizer.cancelsTouchesInView)
    }

    /// The wash is back to nothing once the finger is gone, whatever it did.
    @Test func theWashClearsAfterAHold() {
        let view = chip()
        let affordance = ActionAffordance.attach(to: view)
        affordance.debugHold(liftInside: false)
        #expect(affordance.debugWashAlpha == 0)
    }

    /// ⚠️ THE HOLD SHARES ONLY WITH THE CHIP'S OWN RECOGNISERS. Everything
    /// above it — the scroller, the pager — is exactly what a recognised hold
    /// must prevent, which is the freeze.
    @Test func theHoldPreventsEverythingAbove() {
        let scroller = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        let view = chip()
        scroller.addSubview(view)
        let affordance = ActionAffordance.attach(to: view)
        let hold = affordance.debugHoldRecognizer

        let above = affordance.gestureRecognizer(hold, shouldRecognizeSimultaneouslyWith: scroller.panGestureRecognizer)
        let own = affordance.gestureRecognizer(hold, shouldRecognizeSimultaneouslyWith: affordance.debugTapRecognizer)

        #expect(above == false)
        #expect(own)
    }

    @Test func aMenuIsInstalledOnlyWhileThereIsOne() {
        // Held here: the affordance keeps its view weakly, as a view's
        // behaviour should.
        let view = chip()
        let affordance = ActionAffordance.attach(to: view)
        #expect(affordance.debugHasMenu == false)

        affordance.menuProvider = { UIMenu(children: []) }
        #expect(affordance.debugHasMenu)

        affordance.menuProvider = nil
        #expect(affordance.debugHasMenu == false)
    }

    /// Attaching twice hands the SAME affordance the new action — a recycled
    /// chip must not stack recognisers.
    @Test func attachingAgainReplacesTheAction() {
        var first = 0, second = 0
        let view = chip()
        let a = ActionAffordance.attach(to: view) { first += 1 }
        let b = ActionAffordance.attach(to: view) { second += 1 }

        b.debugTap()

        #expect(a === b)
        #expect(first == 0)
        #expect(second == 1)
        #expect(view.gestureRecognizers?.filter { $0 is UILongPressGestureRecognizer }.count == 1)
    }
}

/// The stake menu the rail and every card raise.
@MainActor
struct StakeMenuTests {
    private func state(
        balance: Int = 250, staked: Int = 0, undoable: Int = 0, shots: Int = 0
    ) -> StakeMenu.State {
        StakeMenu.State(
            balance: balance, stakedOnTarget: staked, undoable: undoable,
            perTargetCap: 250, tapAmount: 1, shotsLeft: shots, shotAmount: 10
        )
    }

    private func actions(_ elements: [UIMenuElement]) -> [UIAction] {
        elements.compactMap { $0 as? UIAction }
    }

    private func titles(_ elements: [UIMenuElement]) -> [String] {
        actions(elements).map(\.title)
    }

    /// No pack: the only amount on offer is the default; the ×10 is there,
    /// DISABLED, and says where to get it.
    @Test func withoutAPackOnlyTheDefaultIsOffered() throws {
        let elements = StakeMenu.elements(for: state(), stake: { _ in }, shoot: {}, undo: nil)
        #expect(titles(elements) == ["×10", "1 point"])
        let shot = try #require(actions(elements).first)
        #expect(shot.attributes.contains(.disabled))
        #expect(shot.subtitle == "Get ×10 cartridges in the Shop")
        #expect(actions(elements)[1].attributes.contains(.disabled) == false)
    }

    /// A loaded pack: "×10 — N left", enabled, and it asks for a SHOT, not an
    /// amount.
    @Test func aLoadedPackOffersTheShotWithItsCount() throws {
        var shots = 0
        var amounts: [Int] = []
        let elements = StakeMenu.elements(
            for: state(shots: 7), stake: { amounts.append($0) }, shoot: { shots += 1 }, undo: nil
        )
        #expect(titles(elements) == ["×10 — 7 left", "1 point"])
        let shot = try #require(actions(elements).first)
        #expect(shot.attributes.contains(.disabled) == false)
        #expect(shot.subtitle == "10 points in one tap")

        shot.performWithSender(nil, target: nil)
        actions(elements)[1].performWithSender(nil, target: nil)
        #expect(shots == 1)
        #expect(amounts == [1])
    }

    /// A shot is worth its whole number: short of the points, or of room on
    /// the post, it is disabled — and says which.
    @Test func aShotThatCannotFireWhollyIsDisabled() {
        #expect(state(balance: 9, shots: 3).canShoot == false)
        #expect(state(staked: 245, shots: 3).canShoot == false)
        #expect(state(balance: 10, staked: 240, shots: 3).canShoot)

        let broke = actions(StakeMenu.elements(for: state(balance: 9, shots: 3), stake: { _ in }, shoot: {}, undo: nil))
        #expect(broke.first?.subtitle == "Not enough points")
        let nearlyFull = actions(StakeMenu.elements(for: state(staked: 245, shots: 3), stake: { _ in }, shoot: {}, undo: nil))
        #expect(nearlyFull.first?.subtitle == "Only 5 points more fit on this post")
    }

    @Test func aFullPostDisablesEverySpend() {
        let elements = StakeMenu.elements(for: state(staked: 250, shots: 4), stake: { _ in }, shoot: {}, undo: nil)
        #expect(actions(elements).allSatisfy { $0.attributes.contains(.disabled) })
        #expect(state(staked: 250).canTap == false)
    }

    @Test func undoAppearsOnlyWithSomethingToTakeBack() {
        let none = StakeMenu.elements(for: state(), stake: { _ in }, shoot: {}, undo: {})
        #expect(titles(none).contains { $0.hasPrefix("Undo") } == false)

        let some = StakeMenu.elements(for: state(undoable: 30), stake: { _ in }, shoot: {}, undo: {})
        #expect(titles(some).last == "Undo stakes (30)")
    }

    /// Near the cap a tap costs only the remainder, so that is what decides.
    @Test func aTapNearTheCapIsJudgedOnTheRemainder() {
        #expect(state(balance: 1, staked: 249).canTap)
        #expect(state(balance: 0, staked: 249).canTap == false)
    }

    @Test func pointsAreCountedInEnglish() {
        #expect(StakeMenu.points(1) == "1 point")
        #expect(StakeMenu.points(10) == "10 points")
    }
}
