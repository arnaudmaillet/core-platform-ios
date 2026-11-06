import Testing
import UIKit
@testable import DesignSystem

/// One at a time (#2143): ONE result toast — a new one replaces the one up;
/// a condition ("Offline") holds its own line, the result under it; the same
/// `id` (or the same words) updates in place — a loading toast becomes its
/// outcome.
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
        ToastView.present(message, symbol: nil, style: style, undoable: undoable, id: id, in: container)
    }

    // MARK: - One at a time

    /// A new result toast replaces the one up — a failure, a confirmation,
    /// an undo alike; there is never a second.
    @Test func aResultReplacesTheOneUp() {
        hosting { container, _ in
            let saved = toast("Saved", in: container)
            let failed = toast("Couldn't send", style: .failure, in: container)
            #expect(saved.isDismissing)
            #expect(ToastView.stack(in: container) == [failed])
            var commits = 0
            let undo = toast("Unfollowed", undoable: .init(commit: { commits += 1 }, undo: {}), in: container)
            #expect(failed.isDismissing)
            let copied = toast("Copied", in: container)
            #expect(undo.isDismissing)
            #expect(commits == 1, "the undo it replaced was lost")
            #expect(ToastView.stack(in: container) == [copied])
        }
    }

    /// A result replacing one that has arrived takes over its capsule where
    /// it stands — no slide, the old one gone at once — so two capsules never
    /// cross on the same line (#2143, the owner's device check).
    @Test func aReplacementTakesOverTheCapsule() {
        hosting { container, _ in
            let muted = toast("Notifications muted", undoable: .init(commit: {}, undo: {}), in: container)
            container.layoutIfNeeded()
            let on = toast("Notifications on", in: container)
            #expect(muted.superview == nil, "the replaced capsule is still there")
            #expect(on.tookOver)
            #expect(on.entranceTravel == 0, "the replacement slid in")
            #expect(ToastView.stack(in: container) == [on])
        }
    }

    /// A condition holds its line: results come and go under it, and none
    /// replaces it; a second condition takes a line of its own.
    @Test func aConditionHoldsItsLine() {
        hosting { container, _ in
            let offline = ToastView.present(
                "Offline", symbol: nil, style: .confirmation, id: "connectivity", isCondition: true, in: container
            )
            let saved = toast("Saved", in: container)
            let failed = toast("Couldn't send", style: .failure, in: container)
            #expect(!offline.isDismissing)
            #expect(saved.isDismissing)
            #expect(ToastView.stack(in: container) == [offline, failed])
            container.layoutIfNeeded()
            #expect(failed.frame.minY >= offline.frame.maxY + ToastView.stackGap - 0.5)
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
            #expect(ToastView.stack(in: container).count == 1)
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

    /// Under a condition, a loading toast still becomes its outcome in
    /// place, on its own line.
    @Test func anUpdateUnderAConditionStaysInPlace() {
        hosting { container, _ in
            let offline = ToastView.present(
                "Offline", symbol: nil, style: .confirmation, id: "connectivity", isCondition: true, in: container
            )
            let loading = toast("Posting…", style: .loading, id: "post", in: container)
            let done = toast("Couldn't post", style: .failure, id: "post", in: container)
            #expect(done === loading)
            #expect(ToastView.stack(in: container) == [offline, loading])
        }
    }

    // MARK: - Feedback

    @Test func feedbackLoadsThenUpdates() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let screen = UIViewController()
        window.rootViewController = screen
        window.isHidden = false
        defer {
            window.rootViewController = nil
            window.isHidden = true
            window.layoutIfNeeded()
        }
        var loading: ToastView?
        let whileLoading = HapticRecorder.recording {
            loading = Feedback.loading("Posting…", id: "post-1", from: screen)
        }
        #expect(whileLoading.isEmpty, "loading plays no haptic")
        let played = HapticRecorder.recording {
            let posted = Feedback.success("Posted", from: screen, id: "post-1")
            #expect(posted === loading)
        }
        #expect(played == [.success])
    }
}
