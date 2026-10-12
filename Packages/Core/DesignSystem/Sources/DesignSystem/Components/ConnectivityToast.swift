import UIKit

/// The app-wide answer to "is it me or the network?" (#793), as a toast
/// (#955): "Offline" at the top for as long as the network is gone — a
/// condition toast, which stays — then, when it returns, the same toast
/// updated in place to "Back online", which leaves on its own.
///
/// It only says what it is told (`follow(isOnline:)`); the app wires it to
/// its connectivity monitor (`OfflineIndicator`). Online from the start, it
/// says nothing — "Back online" only ever follows "Offline".
@MainActor
public final class ConnectivityToast {
    /// The screen the toasts are fired from: the app window's root, whose
    /// topmost screen `Feedback` resolves as the host.
    private let host: () -> UIViewController?
    /// The toast up for the connection, if any (tests, DEBUG).
    public private(set) var shown: ToastView?
    private var saidOffline = false

    static let id = "connectivity"

    public init(host: @escaping () -> UIViewController?) {
        self.host = host
    }

    /// The network is (or is not) there now.
    public func follow(isOnline: Bool) {
        guard let source = host() else { return }
        if !isOnline {
            guard !saidOffline || shown?.superview == nil else { return }
            saidOffline = true
            shown = Feedback.condition("Offline", symbol: "wifi.slash", id: Self.id, from: source)
        } else if saidOffline {
            saidOffline = false
            // The way back is part of the message: the same toast, updated —
            // a notice, with no haptic (nothing the viewer did succeeded).
            shown = Feedback.info("Back online", symbol: "wifi", from: source, at: .top, id: Self.id)
        }
    }
}
