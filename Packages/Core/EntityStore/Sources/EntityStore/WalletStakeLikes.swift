import CoreModels
import CoreStorage
import Foundation

/// Moves a post's like count in the `EntityStore` by every point the viewer
/// stakes on it, wherever it was staked — the feed's rail, a card's chip, the
/// comments bar — and back by every undo and every refund (#896).
///
/// A like is a point (#676), and the server's count is the sum of everyone's:
/// once a stake is committed, the server's count includes it. So the count a
/// screen draws is the store's, the viewer's stake included as the server will
/// include it, and no screen adds the stake on its own. Adding it at the
/// screen counted a committed stake twice (the server's count already holds
/// it), and put two numbers on one post: the feed's badge said 272 while the
/// card it opened from said 271.
///
/// One per app, beside the one `WalletStore`. It diffs the wallet's per-post
/// totals at every change, so it needs no hook in any surface. A change of
/// owner (another account, a profile switch) is a new baseline, never a
/// delta: the next account's stakes are not points placed now.
///
/// ⚠️ A count read from the server before a stake was committed shows the
/// count without it until the next read — what an optimistic count costs.
public final class WalletStakeLikes: @unchecked Sendable {
    private let wallet: WalletStore
    private let entities: EntityStore
    private let scope: StorageScope
    private let lock = NSLock()
    private var baseline: [String: Int]
    private var owner: StorageScope.Owner
    private var observer: NSObjectProtocol?

    public init(wallet: WalletStore, entities: EntityStore, scope: StorageScope = .shared) {
        self.wallet = wallet
        self.entities = entities
        self.scope = scope
        owner = scope.owner
        baseline = Self.totals(of: wallet)
        observer = NotificationCenter.default.addObserver(
            forName: WalletStore.didChangeNotification, object: wallet, queue: nil
        ) { [weak self] _ in
            self?.walletDidChange()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Internal for tests: the wallet moved — on whatever thread moved it.
    func walletDidChange() {
        let deltas: [String: Int] = lock.withLock {
            let latest = Self.totals(of: wallet)
            let current = scope.owner
            defer { baseline = latest }
            guard current == owner else {
                owner = current
                return [:]
            }
            var deltas: [String: Int] = [:]
            for target in Set(latest.keys).union(baseline.keys) {
                let delta = (latest[target] ?? 0) - (baseline[target] ?? 0)
                if delta != 0 { deltas[target] = delta }
            }
            return deltas
        }
        for (target, delta) in deltas {
            entities.addLikes(Int64(delta), to: PostID(target))
        }
    }

    private static func totals(of wallet: WalletStore) -> [String: Int] {
        Dictionary(wallet.stakes().map { ($0.targetID, $0.amount) }, uniquingKeysWith: +)
    }
}
