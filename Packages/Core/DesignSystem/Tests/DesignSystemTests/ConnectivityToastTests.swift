import Testing
import UIKit
@testable import DesignSystem

/// Offline / Back online as the shared toast (#955): nothing while online,
/// "Offline" that stays while offline, then the same toast updated in place
/// to "Back online", which leaves on its own; and the condition outranks the
/// plain confirmations at the top.
@MainActor
@Suite(.serialized)
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
            #expect(ToastView.stack(at: .top, in: screen.view).isEmpty)
        }
    }

    /// Offline stays, as a condition: no timer, no close button.
    @Test func offlineShowsAndStays() throws {
        try hosting { screen, toast, advance in
            toast.follow(isOnline: false)
            let shown = try #require(toast.shown)
            #expect(shown.message == "Offline")
            #expect(shown.position == .top)
            #expect(shown.countdown == nil && shown.closeButton == nil)
            advance(600)
            toast.follow(isOnline: false) // told again: still the one toast
            #expect(!shown.isDismissing)
            #expect(ToastView.stack(at: .top, in: screen.view).count == 1)
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

    /// The condition takes priority over the confirmations at the top.
    @Test func offlinePreemptsConfirmationsAtTheTop() {
        hosting { screen, toast, _ in
            let info = Feedback.info("Saved", from: screen, at: .top)
            toast.follow(isOnline: false)
            #expect(info.isDismissing)
            // …and a failure there does not preempt it.
            _ = Feedback.failure("Couldn't send", from: screen, at: .top)
            #expect(toast.shown?.isDismissing == false)
        }
    }
}
