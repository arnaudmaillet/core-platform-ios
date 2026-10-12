import Testing
import UIKit
@testable import DesignSystem

/// Undoable toasts (#954): the countdown is visible, a tap undoes once and
/// never commits, expiry commits once, a second undoable toast commits the
/// first, the background commits, a finger holds the countdown — and every
/// other way out commits.
///
/// Time is a hand-driven `ToastClock`, swapped and put back synchronously.
@MainActor
@Suite(.serialized)
struct ToastUndoTests {

    private final class Ledger {
        var commits = 0
        var undos = 0
    }

    private func hosting(_ body: (UIView, (TimeInterval) -> Void) throws -> Void) rethrows {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIViewController()
        window.isHidden = false
        window.layoutIfNeeded()
        let (clock, advance) = ToastClock.manual()
        let previousClock = ToastClock.current
        let previousProbe = ToastView.isAssistiveTechnologyRunning
        ToastClock.current = clock
        ToastView.isAssistiveTechnologyRunning = { false }
        defer {
            ToastClock.current = previousClock
            ToastView.isAssistiveTechnologyRunning = previousProbe
            window.rootViewController = nil
            window.isHidden = true
            window.layoutIfNeeded()
        }
        try body(window.rootViewController!.view, advance)
    }

    private func undoable(
        _ ledger: Ledger, position: ToastPosition = .bottom, in container: UIView
    ) -> ToastView {
        ToastView.present(
            "Unfollowed @ava", symbol: nil, style: .confirmation,
            undoable: ToastView.Undoable(commit: { ledger.commits += 1 }, undo: { ledger.undos += 1 }),
            position: position, in: container
        )
    }

    // MARK: - The countdown is visible

    @Test func itWaitsTheUndoDurationWithAVisibleRing() throws {
        try hosting { container, advance in
            let ledger = Ledger()
            let toast = undoable(ledger, in: container)
            #expect(toast.duration == ToastView.undoDuration)
            let ring = try #require(toast.undoButton)
            #expect(toast.closeButton == nil && toast.actionButton == nil)
            #expect(ring.layer.superlayer != nil)
            // Held halfway: the ring stops where the time is.
            advance(4)
            toast.countdown?.hold(.touch)
            #expect(abs(ring.ringFraction - 0.5) < 0.01)
        }
    }

    // MARK: - Undo

    /// A tap undoes, once, and nothing commits — not even when the toast's
    /// time would have run out.
    @Test func aTapUndoesOnceAndNeverCommits() throws {
        try hosting { container, advance in
            let ledger = Ledger()
            let toast = undoable(ledger, in: container)
            let button = try #require(toast.undoButton)
            button.sendActions(for: .primaryActionTriggered)
            button.sendActions(for: .primaryActionTriggered)
            advance(30)
            #expect(ledger.undos == 1)
            #expect(ledger.commits == 0)
            #expect(toast.isDismissing)
        }
    }

    /// VoiceOver undoes through its custom action.
    @Test func voiceOverUndoes() throws {
        try hosting { container, _ in
            let ledger = Ledger()
            let toast = undoable(ledger, in: container)
            let undo = try #require(toast.accessibilityCustomActions?.first { $0.name == "Undo" })
            _ = undo.actionHandler?(undo)
            #expect(ledger.undos == 1 && ledger.commits == 0)
        }
    }

    // MARK: - Commit

    @Test func expiryCommitsOnce() {
        hosting { container, advance in
            let ledger = Ledger()
            let toast = undoable(ledger, in: container)
            advance(ToastView.undoDuration - 0.1)
            #expect(ledger.commits == 0)
            advance(0.2)
            #expect(ledger.commits == 1)
            advance(30)
            toast.resolve(.undone) // too late: refused
            #expect(ledger.commits == 1 && ledger.undos == 0)
        }
    }

    /// One undo slot: a second undoable action commits the first at once —
    /// at any position.
    @Test func aSecondUndoableToastCommitsTheFirst() {
        hosting { container, _ in
            let first = Ledger()
            let second = Ledger()
            _ = undoable(first, position: .top, in: container)
            _ = undoable(second, in: container)
            #expect(first.commits == 1)
            #expect(second.commits == 0 && second.undos == 0)
        }
    }

    /// The app going to the background commits at once.
    @Test func theBackgroundCommits() {
        hosting { container, _ in
            let ledger = Ledger()
            let toast = undoable(ledger, in: container)
            NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
            #expect(ledger.commits == 1)
            #expect(toast.superview == nil)
        }
    }

    /// A finger on it holds the countdown: nothing commits while it is there.
    @Test func aFingerHoldsTheCommit() {
        hosting { container, advance in
            let ledger = Ledger()
            let toast = undoable(ledger, in: container)
            toast.countdown?.hold(.touch)
            advance(60)
            #expect(ledger.commits == 0)
            toast.countdown?.release(.touch)
            advance(ToastView.undoDuration + 0.1)
            #expect(ledger.commits == 1)
        }
    }

    /// Every other way out commits: a swipe or a close, being pushed out of
    /// its stack.
    @Test func leavingAnyOtherWayCommits() {
        hosting { container, _ in
            let dismissed = Ledger()
            undoable(dismissed, in: container).dismiss(animated: false)
            #expect(dismissed.commits == 1)

            // Pushed out of its stack by three newer toasts.
            let pushedOut = Ledger()
            _ = undoable(pushedOut, position: .top, in: container)
            for word in ["One", "Two", "Three"] {
                _ = ToastView.present(word, symbol: nil, style: .confirmation, position: .top, in: container)
            }
            #expect(pushedOut.commits == 1)
        }
    }

    /// Under VoiceOver an undoable toast waits for the viewer (WCAG 2.2.1):
    /// it commits when it leaves, not on a timer.
    @Test func underVoiceOverItWaits() {
        #expect(ToastView.duration(
            for: .confirmation, message: "Unfollowed", hasAction: true, isUndoable: true,
            assistiveTechnologyRunning: true
        ) == nil)
    }

    // MARK: - Feedback

    @Test func feedbackOffersUndo() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let screen = UIViewController()
        window.rootViewController = screen
        window.isHidden = false
        let previous = Feedback.playHaptic
        Feedback.playHaptic = { _ in }
        defer {
            Feedback.playHaptic = previous
            window.rootViewController = nil
            window.isHidden = true
            window.layoutIfNeeded()
        }
        var undone = false
        let toast = Feedback.undoable("Unfollowed @ava", from: screen, commit: {}, undo: { undone = true })
        toast.undoButton?.sendActions(for: .primaryActionTriggered)
        #expect(undone)
    }
}
