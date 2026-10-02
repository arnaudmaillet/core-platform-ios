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
            perTargetCap: 250, tapAmount: 1, shotsLeft: shots, shotAmount: 100
        )
    }

    private func actions(_ elements: [UIMenuElement]) -> [UIAction] {
        elements.compactMap { $0 as? UIAction }
    }

    private func titles(_ elements: [UIMenuElement]) -> [String] {
        actions(elements).map(\.title)
    }

    /// No pack, no Shop to open: the only amount on offer is the default;
    /// the ×100 is there, DISABLED, and says where to get it.
    @Test func withoutAPackOnlyTheDefaultIsOffered() throws {
        let elements = StakeMenu.elements(for: state(), stake: { _ in }, shoot: {}, undo: nil)
        #expect(titles(elements) == ["×100", "1 point"])
        let shot = try #require(actions(elements).first)
        #expect(shot.attributes.contains(.disabled))
        #expect(shot.subtitle == "Get ×100 cartridges in the Shop")
        #expect(actions(elements)[1].attributes.contains(.disabled) == false)
    }

    /// No pack, and a Shop to open: the row is the Shop's DOOR — enabled, and
    /// picking it opens the Shop, never a stake.
    @Test func withoutAPackTheRowOpensTheShop() throws {
        var opened = 0, shots = 0
        let elements = StakeMenu.elements(
            for: state(), stake: { _ in }, shoot: { shots += 1 }, undo: nil, openShop: { opened += 1 }
        )
        #expect(titles(elements) == ["×100", "1 point"])
        let row = try #require(actions(elements).first)
        #expect(row.attributes.contains(.disabled) == false)
        #expect(row.subtitle == "Get ×100 cartridges in the Shop")

        row.performWithSender(nil, target: nil)
        #expect(opened == 1)
        #expect(shots == 0)
    }

    /// The door stays open whatever the post or the balance: it sells the
    /// pack, it spends nothing.
    @Test func theShopDoorIgnoresTheBalanceAndTheCap() {
        let broke = actions(StakeMenu.elements(
            for: state(balance: 0, staked: 250), stake: { _ in }, shoot: {}, undo: nil, openShop: {}
        ))
        #expect(broke.first?.attributes.contains(.disabled) == false)
    }

    /// A loaded pack: "×100 — N left", enabled, and it asks for a SHOT, not an
    /// amount — the Shop's door is gone.
    @Test func aLoadedPackOffersTheShotWithItsCount() throws {
        var shots = 0
        var amounts: [Int] = []
        var opened = 0
        let elements = StakeMenu.elements(
            for: state(shots: 2), stake: { amounts.append($0) }, shoot: { shots += 1 }, undo: nil,
            openShop: { opened += 1 }
        )
        #expect(titles(elements) == ["×100 — 2 left", "1 point"])
        let shot = try #require(actions(elements).first)
        #expect(shot.attributes.contains(.disabled) == false)
        #expect(shot.subtitle == "100 points in one tap")

        shot.performWithSender(nil, target: nil)
        actions(elements)[1].performWithSender(nil, target: nil)
        #expect(shots == 1)
        #expect(amounts == [1])
        #expect(opened == 0)
    }

    /// A shot is worth its whole number: short of the points, or of room on
    /// the post, it is disabled — and says which.
    @Test func aShotThatCannotFireWhollyIsDisabled() {
        #expect(state(balance: 99, shots: 3).canShoot == false)
        #expect(state(staked: 151, shots: 3).canShoot == false)
        #expect(state(balance: 100, staked: 150, shots: 3).canShoot)

        let broke = actions(StakeMenu.elements(for: state(balance: 99, shots: 3), stake: { _ in }, shoot: {}, undo: nil))
        #expect(broke.first?.subtitle == "Not enough points")
        #expect(broke.first?.attributes.contains(.disabled) == true)
        // Two shots on one post leave 50 of the 250: a third does not fit.
        let twoIn = actions(StakeMenu.elements(for: state(staked: 200, shots: 1), stake: { _ in }, shoot: {}, undo: nil))
        #expect(twoIn.first?.subtitle == "Only 50 points more fit on this post")
        #expect(twoIn.first?.attributes.contains(.disabled) == true)
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
        #expect(StakeMenu.points(100) == "100 points")
        #expect(StakeMenu.shotName(100) == "×100")
    }
}

/// The empty-pack row's way to the Shop: up the responder chain to an opener,
/// presented over the top of what is presented.
@MainActor
struct StakeShopTests {
    private final class Opener: UIViewController, StakeShopOpening {
        var built: [UIViewController] = []
        var sells = true
        func makeStakeShop() -> UIViewController? {
            guard sells else { return nil }
            let shop = UIViewController()
            built.append(shop)
            return shop
        }
    }

    /// `root` as a window's root, taken down within the test (a window
    /// released visible in a dirty turn crashes the host).
    private func hosting(_ root: UIViewController, _ body: () throws -> Void) rethrows {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.isHidden = false
        window.layoutIfNeeded()
        defer {
            window.rootViewController = nil
            window.isHidden = true
            window.layoutIfNeeded()
        }
        try body()
    }

    /// A control deep in a screen finds the opener its screen sits under.
    @Test func theOpenerIsFoundUpTheResponderChain() {
        let opener = Opener()
        let screen = UIViewController()
        opener.addChild(screen)
        opener.view.addSubview(screen.view)
        screen.didMove(toParent: opener)
        let control = UIButton()
        screen.view.addSubview(control)

        #expect(StakeShop.opener(from: control) === opener)
        #expect(StakeShop.openAction(from: control) != nil)
    }

    /// No opener up the chain: no action, so the menu row stays disabled.
    @Test func noOpenerMeansNoAction() {
        let control = UIButton()
        UIView().addSubview(control)
        #expect(StakeShop.opener(from: control) == nil)
        #expect(StakeShop.openAction(from: control) == nil)
    }

    /// The Shop lands on the TOP of the stack: over a full-screen feed or a
    /// sheet presented over the shell, never under them.
    @Test func theTopPresenterIsTheLastPresentedController() {
        let root = Opener()
        hosting(root) {
            #expect(StakeShop.topPresenter(over: root) === root)

            let feed = UIViewController()
            feed.modalPresentationStyle = .fullScreen
            root.present(feed, animated: false)
            #expect(StakeShop.topPresenter(over: root) === feed)
        }
    }

    /// Opened from a control on the root screen: the opener builds the Shop
    /// and the top presenter presents it.
    @Test func openingPresentsTheOpenersShop() throws {
        let root = Opener()
        try hosting(root) {
            let control = UIButton()
            root.view.addSubview(control)

            let open = try #require(StakeShop.openAction(from: control))
            open()

            #expect(root.built.count == 1)
            #expect(root.presentedViewController === root.built.first)
        }
    }

    /// An opener that sells nothing presents nothing.
    @Test func anOpenerThatSellsNothingPresentsNothing() throws {
        let root = Opener()
        root.sells = false
        try hosting(root) {
            let control = UIButton()
            root.view.addSubview(control)

            // Bound first: calling `#require`'s result in place crashed the
            // type checker (Swift 6.4, ConstraintSystem assertion).
            let open = try #require(StakeShop.openAction(from: control))
            open()

            #expect(root.presentedViewController == nil)
        }
    }
}
