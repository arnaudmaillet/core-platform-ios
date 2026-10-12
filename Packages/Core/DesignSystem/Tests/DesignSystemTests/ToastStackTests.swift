import Testing
import UIKit
@testable import DesignSystem

/// Stacks, updates and priority (#954): at most three toasts per position,
/// the newest in front and the older ones collapsed behind it; a tap spreads
/// them out; the same `id` (or the same words) updates in place — a loading
/// toast becomes its outcome; a failure preempts the confirmations.
///
/// Time is a hand-driven `ToastClock`, swapped and put back synchronously.
@MainActor
@Suite(.serialized)
struct ToastStackTests {

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

    @discardableResult
    private func toast(
        _ message: String, style: ToastView.Style = .confirmation, id: String? = nil,
        undoable: ToastView.Undoable? = nil, in container: UIView
    ) -> ToastView {
        ToastView.present(message, symbol: nil, style: style, undoable: undoable, id: id, position: .bottom, in: container)
    }

    // MARK: - The stack

    /// Three at most: the fourth pushes the oldest out — a failure too.
    @Test func aPositionShowsAtMostThree() {
        hosting { container, _ in
            let oldest = toast("Couldn't save", style: .failure, in: container)
            toast("Couldn't send", style: .failure, in: container)
            toast("Couldn't copy", style: .failure, in: container)
            toast("Couldn't follow", style: .failure, in: container)
            #expect(oldest.isDismissing)
            #expect(ToastView.stack(at: .bottom, in: container).count == ToastView.maximumStack)
        }
    }

    /// The newest is in front; the older ones sit behind it, narrower, their
    /// content hidden and out of VoiceOver's way.
    @Test func olderToastsCollapseBehindTheNewest() {
        hosting { container, _ in
            let older = toast("Saved to your profile", in: container)
            let newer = toast("Copied", in: container)
            container.layoutIfNeeded()
            #expect(older.isCollapsedBehind)
            #expect(!newer.isCollapsedBehind)
            #expect(older.accessibilityElementsHidden)
            #expect(container.subviews.firstIndex(of: newer)! > container.subviews.firstIndex(of: older)!)
            #expect(older.frame.width < newer.frame.width)
            // It peeks out above the front one (a bottom stack).
            #expect(older.frame.minY < newer.frame.minY)
        }
    }

    /// Spread out, every toast is readable, one above the other, and none
    /// runs out while the viewer reads them; collapsing lets time run again.
    @Test func aSpreadStackIsReadableAndHoldsItsTime() {
        hosting { container, advance in
            // Taller than the front one (an action: 48 pt against 44):
            // spread, it must not overlap it.
            let older = ToastView.present(
                "Saved to your profile", symbol: nil, style: .confirmation,
                action: .init("View") {}, position: .bottom, in: container
            )
            let newer = toast("Copied", in: container)
            ToastView.setSpread(true, at: .bottom, in: container)
            container.layoutIfNeeded()
            #expect(!older.isCollapsedBehind)
            #expect(older.frame.maxY <= newer.frame.minY)
            advance(60)
            #expect(!older.isDismissing && !newer.isDismissing)
            ToastView.setSpread(false, at: .bottom, in: container)
            advance(10)
            #expect(older.isDismissing && newer.isDismissing)
        }
    }

    /// The stack folds back on its own once one toast is left.
    @Test func aLoneToastIsNeverSpread() {
        hosting { container, _ in
            let older = toast("Saved", in: container)
            toast("Copied", in: container)
            ToastView.setSpread(true, at: .bottom, in: container)
            older.dismiss(animated: false)
            #expect(!ToastView.isSpread(at: .bottom, in: container))
        }
    }

    // MARK: - Update and repeat

    /// A loading toast becomes its outcome in place: the same bubble, its
    /// time starting then.
    @Test func aLoadingToastBecomesItsOutcome() {
        hosting { container, advance in
            let loading = toast("Posting…", style: .loading, id: "post", in: container)
            #expect(loading.countdown == nil && loading.closeButton == nil)
            advance(60)
            #expect(!loading.isDismissing)
            let done = toast("Posted", id: "post", in: container)
            #expect(done === loading)
            #expect(done.message == "Posted" && done.style == .confirmation)
            #expect(ToastView.stack(at: .bottom, in: container).count == 1)
            advance(4.1)
            #expect(done.isDismissing)
        }
    }

    /// The same words again are the same toast: its time restarts.
    @Test func aRepeatRestartsTheTime() {
        hosting { container, advance in
            let first = toast("Copied", in: container)
            advance(3)
            let again = toast("Copied", in: container)
            #expect(again === first)
            advance(3)
            #expect(!first.isDismissing)
            advance(1.1)
            #expect(first.isDismissing)
        }
    }

    /// An update brings the toast to the front of its stack.
    @Test func anUpdateComesToTheFront() {
        hosting { container, _ in
            let loading = toast("Posting…", style: .loading, id: "post", in: container)
            toast("Copied", in: container)
            #expect(loading.isCollapsedBehind)
            toast("Couldn't post", style: .failure, id: "post", in: container)
            #expect(ToastView.stack(at: .bottom, in: container).last === loading)
            #expect(!loading.isCollapsedBehind)
        }
    }

    // MARK: - Priority

    /// A failure preempts the confirmations at its position — not an undo,
    /// which must be settled, and not another failure.
    @Test func aFailurePreemptsConfirmations() {
        hosting { container, _ in
            let info = toast("Hidden from this feed", in: container)
            let undo = toast("Unfollowed", undoable: .init(commit: {}, undo: {}), in: container)
            let failure = toast("Couldn't send", style: .failure, in: container)
            #expect(info.isDismissing)
            #expect(!undo.isDismissing)
            #expect(!failure.isDismissing)
        }
    }

    // MARK: - Feedback

    @Test func feedbackLoadsThenUpdates() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let screen = UIViewController()
        window.rootViewController = screen
        window.isHidden = false
        let previous = Feedback.playHaptic
        var played: [UINotificationFeedbackGenerator.FeedbackType] = []
        Feedback.playHaptic = { played.append($0) }
        defer {
            Feedback.playHaptic = previous
            window.rootViewController = nil
            window.isHidden = true
            window.layoutIfNeeded()
        }
        let loading = Feedback.loading("Posting…", id: "post-1", from: screen)
        #expect(played.isEmpty, "loading plays no haptic")
        let posted = Feedback.success("Posted", from: screen, id: "post-1")
        #expect(posted === loading)
        #expect(played == [.success])
    }
}
