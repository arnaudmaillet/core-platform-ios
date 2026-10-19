import CoreNetworking
import CoreStorage
import UIKit

/// Keeps a member's wallet the server's (#1098): read at launch and on every
/// viewer change, back in the foreground, when the network returns, and when
/// the claim's countdown runs out — the server is the clock, so it is asked
/// rather than the device deciding the claim has opened.
@MainActor
final class WalletServerSync {
    private let wallet: WalletStore
    private let scope: StorageScope
    private var observers: [NSObjectProtocol] = []
    private var wake: Timer?

    init(wallet: WalletStore, scope: StorageScope = .shared) {
        self.wallet = wallet
        self.scope = scope
    }

    func start() {
        let center = NotificationCenter.default
        observers = [
            // A new viewer — a sign-in among them, whose welcome gift the
            // server credits a moment after (#1008): read now, and again
            // shortly.
            center.addObserver(forName: StorageScope.didChangeNotification, object: scope, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                    self?.refreshAgain(after: 3)
                }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            center.addObserver(forName: ConnectivityMonitor.didRecoverNotification, object: ConnectivityMonitor.shared, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            // A claim answered, a refresh applied: the countdown it carries
            // may have moved.
            center.addObserver(forName: WalletStore.didChangeNotification, object: wallet, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.armWake() }
            },
        ]
        refresh()
    }

    private func refresh() {
        guard case .member = scope.owner else { return }
        let wallet = wallet
        Task { await wallet.refreshFromServer() }
    }

    private func refreshAgain(after delay: TimeInterval) {
        Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// One read just after `next_claim_at`: the claim opens when the server
    /// says so.
    private func armWake() {
        wake?.invalidate()
        wake = nil
        let snapshot = wallet.snapshot()
        guard snapshot.likesCap != nil, !snapshot.claimAvailable, let next = snapshot.nextClaimAt else { return }
        let delay = max(1, next.timeIntervalSinceNow + 1)
        wake = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
}
