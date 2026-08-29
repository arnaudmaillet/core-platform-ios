import CoreStorage
import DesignSystem
import UIKit

/// The wallet's toolbar face, and everything that keeps it true.
///
/// The balance stands in four headers now — Maps, For You, Profile, and the
/// post screen — and each of them needs the same four things around it: a badge
/// whose count is current, a wake-up for the moment the hourly claim unlocks
/// (the one state change that arrives by CLOCK, so no notification announces
/// it), a re-installed bar item whenever the count changes width, and the sheet
/// the badge presents. Written per host, that is the same forty lines four
/// times, and the third copy is where they start to drift.
///
/// So it is one object per host: it owns the badge and hands out the ITEM.
///
/// ⚠️ A badge is a view and a view lives in one bar. Each host builds its own
/// installer; what is shared is the behaviour, not the instance.
@MainActor
final class WalletBadgeInstaller {
    private let wallet: WalletStore
    private let badge = WalletBadgeButton()
    /// The presenting screen, for the sheet.
    private weak var presenter: UIViewController?
    /// Where the item goes, and how the host re-applies a fresh one. Called on
    /// install and again whenever the count's width changes.
    private let apply: (UIBarButtonItem) -> Void

    /// Wakes the badge when the hourly claim unlocks. One-shot, re-armed from
    /// every refresh.
    private var claimUnlockTimer: Timer?
    /// The store-change half of the badge's freshness — spends and claims,
    /// wherever they happen.
    private var observer: NSObjectProtocol?

    /// - Parameter apply: hands the host a bar item to install. Called
    ///   immediately, and again with a FRESH item whenever the count's fitted
    ///   width changes — re-assigning the same item hands the bar the same
    ///   wrapper at the same frozen size (measured in-sim: "120" still wrapped),
    ///   so a new item is the only thing a bar measures anew.
    init(
        wallet: WalletStore,
        presenter: UIViewController?,
        apply: @escaping (UIBarButtonItem) -> Void
    ) {
        self.wallet = wallet
        self.presenter = presenter
        self.apply = apply

        badge.addAction(
            UIAction { [weak self] _ in self?.presentSheet() },
            for: .primaryActionTriggered
        )
        badge.onFittedWidthChange = { [weak self] in
            guard let self else { return }
            self.apply(self.makeItem())
        }
        observer = NotificationCenter.default.addObserver(
            forName: WalletStore.didChangeNotification,
            object: wallet,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        apply(makeItem())
        refresh()
    }

    // NO `deinit` TEARDOWN, and none is needed: an installer lives exactly as
    // long as its tab coordinator, which lives as long as the process. Both
    // held registrations capture `self` weakly, so even an early release only
    // leaves a timer to fire once into nothing — and a `deinit` could not touch
    // either of them in any case, being nonisolated where this state is
    // main-actor.

    /// A fresh wrapper around the same badge.
    ///
    /// `sharesBackground = false` is not cosmetic: iOS 26 draws ONE glass
    /// background behind adjacent bar items, so without the opt-out the badge
    /// and its neighbour fuse into a single pill.
    private func makeItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(customView: badge)
        item.sharesBackground = false
        item.accessibilityLabel = "Points balance"
        return item
    }

    /// Renders one wallet snapshot onto the badge, and arms the wake-up for the
    /// moment the countdown ends.
    private func refresh() {
        let snapshot = wallet.snapshot()
        badge.update(
            balance: snapshot.balance,
            claimAvailable: snapshot.claimAvailable,
            claimProgress: snapshot.claimCountdown.map {
                WalletBadgeButton.ClaimProgress(fraction: $0.fraction, remaining: $0.remaining)
            }
        )

        claimUnlockTimer?.invalidate()
        claimUnlockTimer = nil
        guard let unlockAt = snapshot.nextClaimAt else { return }
        // +1s so the re-read lands strictly past the gate, never on it.
        let timer = Timer(
            fire: unlockAt.addingTimeInterval(1), interval: 0, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        claimUnlockTimer = timer
    }

    func presentSheet() {
        presenter?.present(WalletClaimViewController(wallet: wallet), animated: true)
    }
}
