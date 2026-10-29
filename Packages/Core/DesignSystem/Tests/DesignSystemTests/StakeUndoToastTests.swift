import Testing
import UIKit
@testable import DesignSystem

/// A stake's undo toast (#957): one per post and surface, updated by every
/// tap of a burst, Undo for the whole burst, no haptic of its own, and closed
/// by the surface when the burst can no longer be taken back.
@MainActor
@Suite(.serialized)
struct StakeUndoToastTests {
    @MainActor private final class Ledger {
        var undos = 0
        let recorder = HapticRecorder()
        var haptics: Int { recorder.played.count }
        var commits = 0
        var advance: (TimeInterval) -> Void = { _ in }
    }

    private func hosting(_ body: (UIViewController, Ledger) throws -> Void) rethrows {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let screen = UIViewController()
        window.rootViewController = screen
        window.isHidden = false
        window.layoutIfNeeded()
        let ledger = Ledger()
        let (clock, advance) = ToastClock.manual()
        ledger.advance = advance
        let previousClock = ToastClock.current
        ToastClock.current = clock
        defer {
            ToastClock.current = previousClock
            window.rootViewController = nil
            window.isHidden = true
            window.layoutIfNeeded()
        }
        try Haptics.$recorder.withValue(ledger.recorder) { try body(screen, ledger) }
    }

    /// Tap after tap on one post: one toast, saying the burst so far.
    @Test func aBurstIsOneToastUpdatedInPlace() {
        hosting { screen, ledger in
            let first = StakeMenu.undoToast(staked: 1, on: "post-1", from: screen) { ledger.undos += 1 }
            let second = StakeMenu.undoToast(staked: 3, on: "post-1", from: screen) { ledger.undos += 1 }
            #expect(first === second)
            #expect(second.message == "Staked 3 likes")
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

    /// Closed by the surface (it moved on): no Undo left, nothing undone —
    /// the burst is sent, once.
    @Test func closingLeavesWithoutUndoing() {
        hosting { screen, ledger in
            let toast = StakeMenu.undoToast(
                staked: 1, on: "post-1", from: screen, commit: { ledger.commits += 1 }
            ) { ledger.undos += 1 }
            StakeMenu.closeUndoToast(toast)
            StakeMenu.closeUndoToast(toast)
            #expect(toast.isDismissing)
            #expect(ledger.undos == 0)
            #expect(ledger.commits == 1)
        }
    }

    /// The toast IS the undo window (#1375): its countdown ending sends the
    /// burst — and a burst numbered by `Burst` is sent once, by its LAST
    /// toast, however many taps updated it in place.
    @Test func theCountdownEndingSendsTheBurstOnce() {
        hosting { screen, ledger in
            let burst = StakeMenu.Burst()
            @MainActor func tap(_ amount: Int) -> ToastView {
                let generation = burst.next()
                return StakeMenu.undoToast(
                    staked: amount, on: "post-1", from: screen,
                    commit: { if burst.isCurrent(generation) { ledger.commits += 1 } }
                ) { ledger.undos += 1 }
            }
            _ = tap(1)
            _ = tap(2)
            let toast = tap(3)
            #expect(ledger.commits == 0, "an in-place update is not an end")
            ledger.advance(60)
            #expect(toast.isDismissing)
            #expect(ledger.commits == 1)
            #expect(ledger.undos == 0)
        }
    }

    /// Undo takes the burst back: nothing is sent, then or later.
    @Test func anUndoneBurstIsNeverSent() throws {
        try hosting { screen, ledger in
            let toast = StakeMenu.undoToast(
                staked: 2, on: "post-1", from: screen, commit: { ledger.commits += 1 }
            ) { ledger.undos += 1 }
            try #require(toast.undoButton).sendActions(for: .primaryActionTriggered)
            ledger.advance(60)
            StakeMenu.closeUndoToast(toast)
            #expect(ledger.undos == 1)
            #expect(ledger.commits == 0)
        }
    }

    /// A burst's numbering: only the latest toast is current.
    @Test func aBurstNumbersItsToasts() {
        let burst = StakeMenu.Burst()
        let first = burst.next()
        let second = burst.next()
        #expect(!burst.isCurrent(first))
        #expect(burst.isCurrent(second))
    }

    /// Another post is another toast.
    @Test func anotherPostIsAnotherToast() {
        hosting { screen, _ in
            let one = StakeMenu.undoToast(staked: 1, on: "post-1", from: screen) {}
            let two = StakeMenu.undoToast(staked: 1, on: "post-2", from: screen) {}
            #expect(one !== two)
            #expect(two.message == "Staked 1 like")
        }
    }
}
