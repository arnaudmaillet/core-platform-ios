import Testing
import UIKit
@testable import DesignSystem

/// Offline / Back online as the shared toast (#955): nothing while online,
/// "Offline" that stays while offline, then the same toast updated in place
/// to "Back online", which leaves on its own; and the condition outranks the
/// plain confirmations at the top.
@MainActor
@Suite(.serialized, .ownsToastClock)
struct ConnectivityToastTests {

    private func hosting(_ body: (UIViewController, ConnectivityToast, (TimeInterval) -> Void) throws -> Void) rethrows {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let screen = UIViewController()
        window.rootViewController = screen
        window.isHidden = false
        window.layoutIfNeeded()
        let (clock, advance) = ToastClock.manual()
        let previousClock = ToastClock.current
        ToastClock.current = clock
        defer {
            ToastClock.current = previousClock
            window.rootViewController = nil
            window.isHidden = true
            window.layoutIfNeeded()
        }
        // The toasts' haptics are recorded, never played.
        _ = try HapticRecorder.recording { try body(screen, ConnectivityToast { [weak screen] in screen }, advance) }
    }

    @Test func nothingShowsWhileOnline() {
        hosting { screen, toast, _ in
            toast.follow(isOnline: true)
            toast.follow(isOnline: true)
            #expect(toast.shown == nil)
            #expect(ToastView.stack(in: screen.view).isEmpty)
        }
    }

    /// Offline stays, as a condition: no timer, no close button.
    @Test func offlineShowsAndStays() throws {
        try hosting { screen, toast, advance in
            toast.follow(isOnline: false)
            let shown = try #require(toast.shown)
            #expect(shown.message == "Offline")
            #expect(shown.isCondition)
            #expect(shown.countdown == nil && shown.closeButton == nil)
            advance(600)
            toast.follow(isOnline: false) // told again: still the one toast
            #expect(!shown.isDismissing)
            #expect(ToastView.stack(in: screen.view).count == 1)
        }
    }

    /// Recovery updates the same toast in place, which then leaves.
    @Test func recoveryUpdatesInPlaceAndLeaves() throws {
        try hosting { _, toast, advance in
            toast.follow(isOnline: false)
            let offline = try #require(toast.shown)
            toast.follow(isOnline: true)
            #expect(toast.shown === offline)
            #expect(offline.message == "Back online")
            advance(4.1)
            #expect(offline.isDismissing)
        }
    }

    /// "Back online" — the same toast, updated — keeps the top line with a
    /// result up under it: no swap, and the result is not replaced.
    @Test func backOnlineKeepsTheTopLine() throws {
        try hosting { screen, toast, _ in
            toast.follow(isOnline: false)
            let offline = try #require(toast.shown)
            let saved = Feedback.success("Saved", from: screen)
            toast.follow(isOnline: true)
            #expect(offline.message == "Back online")
            #expect(!saved.isDismissing)
            #expect(ToastView.stack(in: screen.view) == [offline, saved])
        }
    }

    /// "Offline" holds the top line (#2143): a result toast up stays, under
    /// it, and one fired meanwhile replaces that one — never "Offline".
    @Test func offlineHoldsTheTopLineWithAResultUnderIt() throws {
        try hosting { screen, toast, _ in
            let info = Feedback.info("Saved", from: screen)
            toast.follow(isOnline: false)
            let offline = try #require(toast.shown)
            #expect(!info.isDismissing)
            #expect(ToastView.stack(in: screen.view) == [offline, info])
            let failure = Feedback.failure("Couldn't send", from: screen)
            #expect(!offline.isDismissing)
            #expect(info.isDismissing)
            #expect(ToastView.stack(in: screen.view) == [offline, failure])
        }
    }
}
