import CoreStorage
import DesignSystem
import UIKit

/// The hourly claim, as both wallet screens make it (#1476): the Claim
/// sheet's button and the hub's Claim action are one claim.
///
/// The claim on its way (#1098) keeps its key: minted once for the tap and
/// sent again by a retry — the server credits a key at most once — and
/// dropped once the server has answered.
@MainActor
final class WalletClaimer {
    private let wallet: WalletStore
    /// The key of the claim on its way; nil when none is.
    private(set) var pendingKey: String?
    /// Posted when the claim's state changed (sent, answered): redraw what
    /// shows it. Both wallet screens listen.
    static let didChangeNotification = Notification.Name("wallet.claimer.didChange")
    /// Posted when a claim was credited: the balance has its new value.
    static let didClaimNotification = Notification.Name("wallet.claimer.didClaim")

    private func changed() { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }

    init(wallet: WalletStore) {
        self.wallet = wallet
    }

    var isPending: Bool { pendingKey != nil }

    /// Claims, once: a second tap while one is on its way does nothing. A
    /// claim the server did not answer asks, over `host`, to try again with
    /// the same key.
    func claim(presentingFrom host: UIViewController) {
        guard pendingKey == nil else { return }
        let key = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        pendingKey = key
        changed()
        send(key, host: host)
    }

    private func send(_ key: String, host: UIViewController) {
        Task { @MainActor [weak self, weak host] in
            guard let self else { return }
            let outcome = await wallet.claim(idempotencyKey: key)
            switch outcome {
            case .claimed(let awarded):
                pendingKey = nil
                // One haptic and one toast per claim (#1479): the toast's own
                // success haptic is the claim's.
                if let host {
                    Feedback.success(Self.toastText(awarded: awarded), from: host)
                } else {
                    Haptics.play(.success)
                }
                changed()
                NotificationCenter.default.post(name: Self.didClaimNotification, object: self)
            case .tooEarly, .dailyCapReached, .balanceFull:
                pendingKey = nil
                Haptics.play(.warning)
                changed()
            case .unavailable:
                // Not answered: the same key goes again with the retry, so a
                // claim whose answer was lost is never paid twice.
                Haptics.play(.error)
                guard let host else {
                    pendingKey = nil
                    changed()
                    return
                }
                let alert = UIAlertController(
                    title: nil, message: "Couldn't reach the server to claim. Try again.", preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                    self?.pendingKey = nil
                    self?.changed()
                })
                alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self, weak host] _ in
                    guard let self, let host else { return }
                    send(key, host: host)
                })
                host.present(alert, animated: true)
            }
        }
    }

    /// The claim's toast: "+25 likes".
    static func toastText(awarded: Int) -> String {
        awarded == 1 ? "+1 like" : "+\(awarded.formatted()) likes"
    }

    /// What the Claim button says for `snapshot`.
    static func title(for snapshot: WalletSnapshot, pending: Bool) -> String {
        if pending { return "Claiming…" }
        if snapshot.claimAvailable { return "Claim \(snapshot.claimAmount) likes" }
        if snapshot.claimedToday >= snapshot.dailyClaimCap, let next = snapshot.nextClaimAt {
            return "Daily cap reached — resets in \(countdownString(to: next))"
        }
        if let next = snapshot.nextClaimAt { return "Next claim in \(countdownString(to: next))" }
        // The likes cap (#901): no wait opens it, only spending does.
        if let cap = snapshot.likesCap, snapshot.balance >= cap {
            return "Your likes are full — stake some to claim again"
        }
        return "Claim"
    }

    /// The toolbar's words (#1494): short enough for a capsule at the bar's
    /// trailing end — "Claim 25 likes", "Claim in 42:07".
    static func shortTitle(for snapshot: WalletSnapshot, pending: Bool) -> String {
        if pending { return "Claiming…" }
        if snapshot.claimAvailable { return "Claim \(snapshot.claimAmount) likes" }
        if snapshot.claimedToday >= snapshot.dailyClaimCap, let next = snapshot.nextClaimAt {
            return "Cap reached · \(countdownString(to: next))"
        }
        if let next = snapshot.nextClaimAt { return "Claim in \(countdownString(to: next))" }
        if let cap = snapshot.likesCap, snapshot.balance >= cap { return "Likes full" }
        return "Claim"
    }

    /// "42:07" under an hour, "3h 12m" above it.
    static func countdownString(to date: Date, now: Date = Date()) -> String {
        let remaining = max(0, Int(date.timeIntervalSince(now).rounded(.up)))
        if remaining >= 3600 {
            return "\(remaining / 3600)h \((remaining % 3600) / 60)m"
        }
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }
}
