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
    private func state(balance: Int = 250, staked: Int = 0, undoable: Int = 0) -> StakeMenu.State {
        StakeMenu.State(
            balance: balance, stakedOnTarget: staked, undoable: undoable,
            perTargetCap: 250, denominations: [100], tapAmount: 10
        )
    }

    private func titles(_ elements: [UIMenuElement]) -> [String] {
        elements.compactMap { ($0 as? UIAction)?.title }
    }

    @Test func maxNamesTheRealSpend() {
        let elements = StakeMenu.elements(for: state(balance: 60), stake: { _ in }, undo: nil)
        #expect(titles(elements) == ["Max (60 points)", "100 points"])
        let hundred = elements[1] as? UIAction
        #expect(hundred?.attributes.contains(.disabled) == true)
    }

    @Test func aFullPostDisablesEverySpend() {
        let elements = StakeMenu.elements(for: state(staked: 250), stake: { _ in }, undo: nil)
        #expect(elements.compactMap { $0 as? UIAction }.allSatisfy { $0.attributes.contains(.disabled) })
        #expect(state(staked: 250).canTap == false)
    }

    @Test func undoAppearsOnlyWithSomethingToTakeBack() {
        let none = StakeMenu.elements(for: state(), stake: { _ in }, undo: {})
        #expect(titles(none).contains { $0.hasPrefix("Undo") } == false)

        let some = StakeMenu.elements(for: state(undoable: 30), stake: { _ in }, undo: {})
        #expect(titles(some).last == "Undo stakes (30)")
    }

    /// Near the cap a tap costs only the remainder, so that is what decides.
    @Test func aTapNearTheCapIsJudgedOnTheRemainder() {
        #expect(state(balance: 5, staked: 245).canTap)
        #expect(state(balance: 4, staked: 245).canTap == false)
    }
}
