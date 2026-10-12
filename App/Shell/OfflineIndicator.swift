import CoreNetworking
import DesignSystem
import UIKit

/// The app-wide answer to "is it me or the network?" (#793): **Offline** at
/// the top while the network is gone, turning into **Back online** when it
/// returns, then gone.
///
/// Since #955 it is the shared toast (`ConnectivityToast`, a condition toast
/// in the scene's overlay) rather than a capsule of its own in a private
/// window: the same glass, motion, Reduce Motion handling and announcement as
/// every other toast, and the condition outranks the plain confirmations up
/// at the top. It states a condition; the screens beneath own what to do
/// about it (their failed states offer Try Again, and they reload on
/// recovery).
@MainActor
final class OfflineIndicator {
    private let toast: ConnectivityToast
    private let monitor: ConnectivityMonitor
    nonisolated(unsafe) private var observation: NSObjectProtocol?

    /// Follows `monitor` for `window`.
    @discardableResult
    static func install(on window: UIWindow, monitor: ConnectivityMonitor = .shared) -> OfflineIndicator {
        let indicator = OfflineIndicator(window: window, monitor: monitor)
        indicator.observation = NotificationCenter.default.addObserver(
            forName: ConnectivityMonitor.didChangeNotification, object: monitor, queue: .main
        ) { [weak indicator] _ in
            MainActor.assumeIsolated { indicator?.follow() }
        }
        // Launched offline: said once the shell is the window's root and the
        // window is key — installed before either, a toast would have no
        // screen to be fired from.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak indicator] in indicator?.follow() }
        return indicator
    }

    private init(window: UIWindow, monitor: ConnectivityMonitor) {
        self.monitor = monitor
        toast = ConnectivityToast { [weak window] in window?.rootViewController }
    }

    deinit {
        if let observation { NotificationCenter.default.removeObserver(observation) }
    }

    private func follow() {
        toast.follow(isOnline: monitor.isOnline)
    }

    #if DEBUG
    var debugText: String? { toast.shown?.superview == nil ? nil : toast.shown?.message }
    #endif
}
