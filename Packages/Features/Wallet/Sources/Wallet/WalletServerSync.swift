import CoreNetworking
import CoreStorage
import UIKit

/// Keeps a member's wallet the server's (#1098): read at launch and on every
/// viewer change, back in the foreground, when the network returns, and when
/// the claim's countdown runs out — the server is the clock, so it is asked
/// rather than the device deciding the claim has opened.
@MainActor
public final class WalletServerSync {
    private let wallet: WalletStore
    private let scope: StorageScope
    private var observers: [NSObjectProtocol] = []
    /// The scope's and the wallet's changes, heard from `start()` on.
    private var storeObservations: [StoreObservation] = []
    private var wake: Timer?

    public init(wallet: WalletStore, scope: StorageScope) {
        self.wallet = wallet
        self.scope = scope
    }

    public func start() {
        let center = NotificationCenter.default
        storeObservations = [
            // A new viewer — a sign-in among them, whose welcome gift the
            // server credits a moment after (#1008): read now, and again
            // shortly.
            scope.ownerChanges.observeOnMain { [weak self] in
                self?.refresh()
                self?.refreshAgain(after: 3)
            },
            // A claim answered, a refresh applied: the countdown it carries
            // may have moved.
            wallet.changes.observeOnMain { [weak self] in
                self?.armWake()
            },
        ]
        observers = [
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            center.addObserver(forName: ConnectivityMonitor.didRecoverNotification, object: ConnectivityMonitor.shared, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
        ]
        refresh()
    }

    private func refresh() {
        guard case .member = scope.owner else { return }
        let wallet = wallet
        Task {
            await wallet.refreshFromServer()
            // What the member owns and the catalogue's prices (#1475).
            await wallet.refreshItemsFromServer()
        }
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
