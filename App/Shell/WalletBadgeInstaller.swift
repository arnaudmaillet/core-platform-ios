import CoreNavigation
import CoreStorage
import DesignSystem
import UIKit

/// The wallet's toolbar face, and everything that keeps it true.
///
/// The balance stands in almost every header now — the four root tabs, a pushed
/// profile, and the post screen — and each of them needs the same four things
/// around it: a badge
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
///
/// A tab root's installer is held by its coordinator, for the process's life.
/// A PUSHED screen has no coordinator to hold one, so `attach(to:…)` hangs the
/// installer on the screen itself and it lives exactly as long as the screen.
@MainActor
final class WalletBadgeInstaller: NSObject {
    /// Every host's badge carries the same identifier: iOS 26 treats two items
    /// with one identifier as ONE item across a transition, so a push from a
    /// root wearing the balance to a profile wearing it keeps it in place
    /// rather than cross-fading two copies — and a re-minted item on a width
    /// change is the same slot, not a new one.
    static let itemIdentifier = "shell.wallet-balance"

    private let wallet: WalletStore
    private let badge = WalletBadgeButton()
    /// The presenting screen, for the sheet.
    private weak var presenter: UIViewController?
    /// Builds the sheet the badge presents (`AppContainer.makeWalletSheet`).
    private let makeSheet: () -> UIViewController
    /// Where the item goes, and how the host re-applies a fresh one. Called on
    /// install and again whenever the count's width changes.
    private let apply: (UIBarButtonItem) -> Void

    /// Wakes the badge when the hourly claim unlocks. One-shot, re-armed from
    /// every refresh.
    private var claimUnlockTimer: Timer?

    /// - Parameter apply: hands the host a bar item to install. Called
    ///   immediately, and again with a FRESH item whenever the count's fitted
    ///   width changes — re-assigning the same item hands the bar the same
    ///   wrapper at the same frozen size (measured in-sim: "120" still wrapped),
    ///   so a new item is the only thing a bar measures anew.
    init(
        wallet: WalletStore,
        presenter: UIViewController?,
        makeSheet: @escaping () -> UIViewController,
        apply: @escaping (UIBarButtonItem) -> Void
    ) {
        self.wallet = wallet
        self.presenter = presenter
        self.makeSheet = makeSheet
        self.apply = apply
        super.init()

        badge.addAction(
            UIAction { [weak self] _ in self?.presentSheet() },
            for: .primaryActionTriggered
        )
        badge.onFittedWidthChange = { [weak self] in
            guard let self else { return }
            self.apply(self.makeItem())
        }
        // The store-change half of the badge's freshness — spends and claims,
        // wherever they happen.
        //
        // ⚠️ SELECTOR-BASED, not a block observer, and that is what makes a
        // per-screen installer safe: Foundation drops a selector registration
        // with the object, where a block observer's token lives on in the
        // centre until someone removes it — and a pushed profile's installer
        // dies with the profile, every push, with nobody left to remove it.
        NotificationCenter.default.addObserver(
            self, selector: #selector(walletDidChange),
            name: WalletStore.didChangeNotification, object: wallet
        )
        apply(makeItem())
        refresh()
    }

    /// Hangs a badge on a screen that has no coordinator to hold its installer
    /// — a PUSHED profile — for exactly as long as that screen lives.
    ///
    /// The installer is retained by the screen (an associated object) and
    /// holds the screen only weakly, as its presenter and through `apply`, so
    /// popping the screen releases both. A screen that does not adopt
    /// `HeaderAccessoryHosting` is left alone.
    static func attach(
        to host: UIViewController,
        wallet: WalletStore,
        makeSheet: @escaping () -> UIViewController
    ) {
        guard host is any HeaderAccessoryHosting else { return }
        let installer = WalletBadgeInstaller(
            wallet: wallet, presenter: host, makeSheet: makeSheet
        ) { [weak host] item in
            (host as? any HeaderAccessoryHosting)?.setTrailingAccessoryItem(item)
        }
        objc_setAssociatedObject(
            host, &attachmentKey, installer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    /// The associated-object key `attach` files the installer under. Only its
    /// ADDRESS is used; the value is never read or written.
    nonisolated(unsafe) private static var attachmentKey: UInt8 = 0

    // NO `deinit` TEARDOWN, and none is needed: the store registration is
    // selector-based and goes with the object, and the claim timer captures
    // `self` weakly, so a released installer only leaves a timer to fire once
    // into nothing.

    /// The store posts from whichever thread changed it, so the refresh hops
    /// to the main actor rather than assuming it — the `queue: .main` the block
    /// observer used to say.
    @objc nonisolated private func walletDidChange() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.walletDidChange() }
            return
        }
        MainActor.assumeIsolated { refresh() }
    }

    /// A fresh wrapper around the same badge.
    ///
    /// `sharesBackground = false` is not cosmetic: iOS 26 draws ONE glass
    /// background behind adjacent bar items, so without the opt-out the badge
    /// and its neighbour fuse into a single pill.
    private func makeItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(customView: badge)
        item.sharesBackground = false
        item.identifier = Self.itemIdentifier
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
        presenter?.present(makeSheet(), animated: true)
    }
}
