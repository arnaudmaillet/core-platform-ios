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
            let width = muted.bounds.width
            let on = toast("Notifications on", in: container)
            #expect(muted.superview == nil, "the replaced capsule is still there")
            #expect(on.tookOver)
            // The width on screen: the model's here, or where the unfold has it.
            let startWidth = on.takeOverWidth ?? 0
            #expect(startWidth > 0, "the replacement did not start from the capsule")
            #expect(startWidth <= width + 0.5, "the replacement did not start from the capsule")
            #expect(on.unfoldedFrom == nil, "the replacement unfolded again")
            #expect(ToastView.stack(in: container) == [on])
        }
    }

    /// An update by `id` flows like a replacement: the old content blurs
    /// away and the new one comes out of a blur, centred, in the same capsule
    /// (the owner, 2026-11-06: the change was a cut, the text sliding) —
    /// one capsule, never a second one (#2285).
    @Test func anUpdateFlowsItsContent() {
        hosting { container, _ in
            let loading = toast("Posting…", style: .loading, id: "post", in: container)
            container.layoutIfNeeded()
            let posted = toast("Posted", id: "post", in: container)
            #expect(posted === loading)
            #expect(container.subviews.compactMap { $0 as? ToastView }.count == 1, "a second capsule")
            #expect(posted.debugIsFlowing, "the words were cut in, not opened from the middle")
            // The old words leave from where they stand, about the middle.
            let words = posted.debugLeaving.filter { !($0 is ToastBadge) && !($0 is AppLoaderView) }
            #expect(words.allSatisfy { $0.autoresizingMask.contains([.flexibleLeftMargin, .flexibleRightMargin]) })
        }
    }

    /// The disc is never repainted through the symbol transition (#2285:
    /// it left the disc empty): the old disc leaves, holding the leading
    /// end, as a new one arrives; the action leaves holding the trailing
    /// one.
    @Test func aChangeLeavesItsOldDiscAndPinsItsEnds() {
        hosting { container, _ in
            let muted = ToastView.present(
                "Notifications muted", symbol: "bell.slash.fill", style: .confirmation,
                undoable: .init(commit: {}, undo: {}), in: container
            )
            container.layoutIfNeeded()
            let disc = muted.debugMark
            #expect(disc is ToastBadge)
            let on = ToastView.present("Notifications on", symbol: "bell.fill", style: .confirmation, in: container)
            #expect(on.debugMark is ToastBadge)
            #expect(on.debugMark !== disc, "the old disc was repainted in place")
            let leavingDisc = on.debugLeaving.first { $0 === disc }
            #expect(leavingDisc?.autoresizingMask.contains(.flexibleRightMargin) == true, "the old disc does not keep the leading end")
            let control = on.debugLeaving.first { $0 is ToastActionButton }
            #expect(control?.autoresizingMask.contains(.flexibleLeftMargin) == true, "the action does not keep the trailing end")
        }
    }

    // MARK: - A close turned around (#2285)

    /// A result arriving while the one up is folding away takes that
    /// capsule over where the fold has it: one `ToastView` in the
    /// container, never two on the line. The one closing was committed when
    /// its close began.
    @Test func aResultTakesOverACapsuleThatIsClosing() {
        hosting { container, _ in
            var commits = 0
            let muted = ToastView.present(
                "Notifications muted", symbol: "bell.slash.fill", style: .confirmation,
                undoable: .init(commit: { commits += 1 }, undo: {}), in: container
            )
            container.layoutIfNeeded()
            let restingWidth = muted.bounds.width
            muted.dismiss(animated: true)
            #expect(muted.isDismissing)
            #expect(muted.superview === container, "guard: the close ended at once, the test proves nothing")
            #expect(commits == 1)
            let on = ToastView.present("Notifications on", symbol: "bell.fill", style: .confirmation, in: container)
            #expect(muted.superview == nil, "the closing capsule is still there")
            #expect(container.subviews.compactMap { $0 as? ToastView } == [on], "two capsules on the line")
            #expect(on.tookOver)
            // From where the fold has it: between its circle and its width.
            let turnedAt = on.takeOverWidth ?? 0
            let circle = ToastView.Metrics.minimumHeight - 0.5
            #expect(turnedAt >= circle, "turned around at \(turnedAt)")
            #expect(turnedAt <= restingWidth + 0.5, "turned around at \(turnedAt)")
            #expect(on.unfoldedFrom == nil, "it unfolded from scratch")
            #expect(commits == 1, "the closed undo was settled again")
        }
    }

    /// A condition closing is never taken over: a result arriving then
    /// unfolds on its own.
    @Test func aClosingConditionIsNeverTakenOver() {
        hosting { container, _ in
            let offline = ToastView.present(
                "Offline", symbol: "wifi.slash", style: .confirmation, id: "connectivity", isCondition: true, in: container
            )
            container.layoutIfNeeded()
            offline.dismiss(animated: true)
            let saved = ToastView.present("Saved", symbol: "checkmark.circle.fill", style: .confirmation, in: container)
            #expect(offline.superview === container, "the condition's close was turned around")
            #expect(!saved.tookOver)
        }
    }

    /// A toggle spammed: the latest wins, from what is on screen — never
    /// more than one set of pieces leaving, the latest content showing at
    /// once (the owner, 2026-11-06).
    @Test func aSpammedToggleKeepsOnePieceSetLeaving() {
        hosting { container, _ in
            var last: ToastView?
            for index in 0..<8 {
                let muted = index.isMultiple(of: 2)
                last = ToastView.present(
                    muted ? "Notifications muted" : "Notifications on",
                    symbol: muted ? "bell.slash.fill" : "bell.fill", style: .confirmation,
                    undoable: muted ? .init(commit: {}, undo: {}) : nil, in: container
                )
            }
            let shown = ToastView.stack(in: container)
            #expect(shown.count == 1 && shown.first === last)
            #expect(last?.message == "Notifications on")
            let leaving = last?.debugLeaving ?? []
            #expect(leaving.count <= 2, "pieces of several states piled up: \(leaving.count)")
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
