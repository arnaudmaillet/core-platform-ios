import Foundation

/// Whether the wallet's How it works shows by itself (#1480): once per
/// ACCOUNT on this device, the first time its hub opens — then only from the
/// hub's **?**. A guest has no hub, so never.
public enum WalletHowItWorks {
    static let key = "wallet.howItWorks.seen"
    /// Swappable for tests.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    /// Whether `owner` has not seen it yet.
    public static func shouldShow(for owner: StorageScope.Owner) -> Bool {
        guard case .member(let account, _) = owner else { return false }
        return !(defaults.stringArray(forKey: key) ?? []).contains(account)
    }

    /// Records that `owner` has seen it.
    public static func markSeen(by owner: StorageScope.Owner) {
        guard case .member(let account, _) = owner else { return }
        var seen = defaults.stringArray(forKey: key) ?? []
        guard !seen.contains(account) else { return }
        seen.append(account)
        defaults.set(seen, forKey: key)
    }
}
