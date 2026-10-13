import Testing
import UIKit
@testable import DesignSystem

/// A stake's undo toast (#957): one per post and surface, updated by every
/// tap of a burst, Undo for the whole burst, no haptic of its own, and closed
/// by the surface when the burst can no longer be taken back.
@MainActor
@Suite(.serialized)
struct StakeUndoToastTests {
    private final class Ledger {
        var undos = 0
        var haptics = 0
    }

    private func hosting(_ body: (UIViewController, Ledger) throws -> Void) rethrows {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let screen = UIViewController()
        window.rootViewController = screen
        window.isHidden = false
        window.layoutIfNeeded()
        let ledger = Ledger()
        let (clock, _) = ToastClock.manual()
        let previousClock = ToastClock.current
        let previousHaptic = Feedback.playHaptic
        ToastClock.current = clock
        Feedback.playHaptic = { _ in ledger.haptics += 1 }
        defer {
            ToastClock.current = previousClock
            Feedback.playHaptic = previousHaptic
            window.rootViewController = nil
            window.isHidden = true
            window.layoutIfNeeded()
        }
        try body(screen, ledger)
    }

    /// Tap after tap on one post: one toast, saying the burst so far.
    @Test func aBurstIsOneToastUpdatedInPlace() {
        hosting { screen, ledger in
            let first = StakeMenu.undoToast(staked: 1, on: "post-1", from: screen) { ledger.undos += 1 }
            let second = StakeMenu.undoToast(staked: 3, on: "post-1", from: screen) { ledger.undos += 1 }
            #expect(first === second)
            #expect(second.message == "Staked 3 points")
            #expect(ToastView.stack(at: .bottom, in: screen.view).count == 1)
            #expect(ledger.haptics == 0, "each tap already played its own")
            #expect(ledger.undos == 0)
        }
    }

    /// Undo runs once, for the whole burst; the toast leaves.
    @Test func undoTakesBackTheBurstOnce() throws {
        try hosting { screen, ledger in
            _ = StakeMenu.undoToast(staked: 1, on: "post-1", from: screen) { ledger.undos += 1 }
            let toast = StakeMenu.undoToast(staked: 2, on: "post-1", from: screen) { ledger.undos += 1 }
            let button = try #require(toast.undoButton)
            button.sendActions(for: .primaryActionTriggered)
            button.sendActions(for: .primaryActionTriggered)
            #expect(ledger.undos == 1)
            #expect(toast.isDismissing)
        }
    }

    /// Closed by the surface (it moved on): no Undo left, nothing undone.
    @Test func closingLeavesWithoutUndoing() {
        hosting { screen, ledger in
            let toast = StakeMenu.undoToast(staked: 1, on: "post-1", from: screen) { ledger.undos += 1 }
            StakeMenu.closeUndoToast(toast)
            StakeMenu.closeUndoToast(toast)
            #expect(toast.isDismissing)
            #expect(ledger.undos == 0)
        }
    }

    /// Another post is another toast.
    @Test func anotherPostIsAnotherToast() {
        hosting { screen, _ in
            let one = StakeMenu.undoToast(staked: 1, on: "post-1", from: screen) {}
            let two = StakeMenu.undoToast(staked: 1, on: "post-2", from: screen) {}
            #expect(one !== two)
            #expect(two.message == "Staked 1 point")
        }
    }
}
