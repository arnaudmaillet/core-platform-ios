import Foundation
import Network

/// Whether the app can reach the network, and the moment it can again (#793).
///
/// The app used to have no idea: a call made offline failed like any other,
/// screens showed a generic error, and nothing refreshed when the network
/// came back — the viewer had to find a way to retry, screen by screen.
///
/// One shared monitor answers both questions:
/// - **`isOnline`** — from the system path (`NWPathMonitor`) on a device, or
///   from the mock network's fault switchboard in mock mode (a simulator's
///   path cannot be faked; `report(online:)` is how the mock speaks);
/// - **`didRecoverNotification`** — posted once per offline → online edge, on
///   the main queue. Screens and stores that failed while offline listen and
///   reload; a store with content revalidates quietly.
///
/// Main-actor state, read from the UI; the path monitor's own queue only hands
/// its answers over.
@MainActor
public final class ConnectivityMonitor {
    public static let shared = ConnectivityMonitor()

    /// Posted on every change of `isOnline`.
    public static let didChangeNotification = Notification.Name("ConnectivityMonitor.didChange")
    /// Posted when the network comes back after being lost.
    public static let didRecoverNotification = Notification.Name("ConnectivityMonitor.didRecover")

    public private(set) var isOnline = true

    private var pathMonitor: NWPathMonitor?
    /// How long a loss must last before it is announced: a flapping network
    /// blipped the capsule and set every store reloading on each edge.
    private let offlineGrace: TimeInterval
    private var pendingOffline: DispatchWorkItem?

    public init(offlineGrace: TimeInterval = 1.5) {
        self.offlineGrace = offlineGrace
    }

    /// Follows the system's network path. Idempotent.
    public func startMonitoringSystemPath() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in self?.report(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "ConnectivityMonitor.path"))
        pathMonitor = monitor
    }

    /// Records whether the network is reachable now, announcing a change and,
    /// on the way back, the recovery.
    public func report(online: Bool) {
        if online {
            // A loss that never lasted its grace was never announced.
            pendingOffline?.cancel()
            pendingOffline = nil
        } else if offlineGrace > 0, isOnline, pendingOffline == nil {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.pendingOffline = nil
                    self?.apply(online: false)
                }
            }
            pendingOffline = work
            DispatchQueue.main.asyncAfter(deadline: .now() + offlineGrace, execute: work)
            return
        }
        apply(online: online)
    }

    private func apply(online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        if online {
            NotificationCenter.default.post(name: Self.didRecoverNotification, object: self)
        }
    }

    /// Runs `handler` on every recovery for as long as the returned token is
    /// kept — the one line a store needs to reload after an outage.
    public func onRecovery(_ handler: @escaping @MainActor () -> Void) -> RecoveryObservation {
        RecoveryObservation(token: NotificationCenter.default.addObserver(
            forName: Self.didRecoverNotification, object: self, queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        })
    }
}

/// A recovery subscription; removed when released.
public final class RecoveryObservation: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(token: NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
