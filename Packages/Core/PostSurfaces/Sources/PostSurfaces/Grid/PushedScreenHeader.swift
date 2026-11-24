import CoreNavigation
import CoreStorage
import DesignSystem
import UIKit

/// The header every pushed post screen wears: `[‹] ———— [points][search]`.
/// Written for the screens For You pushed (until #2453); the place page and
/// the post sets push them now.
///
/// No title, on purpose (product call, 2026-09-29, restated 2026-09-30 after
/// #323's large titles were tried and taken back): the back chevron says where
/// the viewer came from and the content says where they are, so a word in the
/// bar — or under it — only competes with both. The trailing run is the
/// root's own, in the root's order — the balance inboard, search at the edge —
/// so the two items read as the same controls carried one level in rather
/// than as a second header.
///
/// `.never` is stated rather than left `.automatic`, and no tab stack turns
/// `prefersLargeTitles` on, so nothing pushed over these screens has a large
/// title to inherit.
///
/// # Why it is an object, and why it is not the shell's installer
///
/// The shell's `WalletBadgeInstaller` owns the root headers' badge and hangs
/// one on a pushed PROFILE through the router. These screens are pushed from
/// inside this package, where the shell's type cannot be reached — the place
/// page and the post screen are in the same position and build their
/// badge locally for the same reason. What the installer exists to share is
/// the freshness rules, and they are small: a store observer, a claim-unlock
/// wake-up, and a FRESH item whenever the count changes width. Written once
/// here, two screens use it (Discover's whole mosaic and the pushed post list;
/// For You's Friends and Following lists until #2453), and each holds its own
/// — a badge is a view, and a view lives in one bar.
///
/// ⚠️ THE BAR ITEMS CARRY THE ROOT'S IDENTIFIERS. iOS 26 treats two items with
/// one identifier as ONE item across a push, so the balance and search stay in
/// place while the rest of the bar transitions, instead of cross-fading two
/// copies of the same controls. The balance's is the shell's own
/// (`WalletBadgeInstaller.itemIdentifier` — spelled out again here because the
/// App target cannot be imported); search's is `BarItems.SharedID.search`, the
/// one the Explore root's search item carries (`ExploreTabCoordinator`).
///
/// Native chrome is UIKit's (`TabBarRevealPolicy`): these screens hide the tab
/// bar with `hidesBottomBarWhenPushed` and write nothing on any bar.
@MainActor
final public class PushedScreenHeader: NSObject {
    /// The balance item's identifier — the shell's `WalletBadgeInstaller
    /// .itemIdentifier`, which every root header's badge carries.
    static let walletItemIdentifier = BarItems.SharedID.walletBalance
    /// Search's, shared with For You's own search item.
    static let searchItemIdentifier = BarItems.SharedID.search

    private let wallet: (any WalletReading)?
    private let makeWalletSheet: (@MainActor () -> UIViewController)?
    private weak var router: (any Router)?
    private weak var host: UIViewController?

    private let badge = WalletBadgeButton()
    private var walletItem: UIBarButtonItem?
    /// Wakes the badge when the hourly claim unlocks — the one state change
    /// that arrives by CLOCK, so no store notification announces it.
    private var claimUnlockTimer: Timer?
    /// The wallet's changes, heard for as long as this header lives: it
    /// replaces a selector registration, which went with the object, so a
    /// pushed screen's header stops hearing when the screen goes (#2376).
    private var walletObservation: StoreObservation?

    private(set) lazy var searchItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: AppSymbol.search.image(),
            primaryAction: UIAction { [weak self] _ in self?.router?.route(to: .search) }
        )
        item.accessibilityLabel = "Search"
        item.identifier = Self.searchItemIdentifier
        return item
    }()

    /// - Parameters:
    ///   - wallet: the app's ONE store (its `changes` are the instance's).
    ///     Nil leaves the header with search alone.
    ///   - makeWalletSheet: the shell's claim sheet. Nil makes the badge a
    ///     read-out: a control with nothing behind it is not offered.
    public init(
        wallet: (any WalletReading)?,
        makeWalletSheet: (@MainActor () -> UIViewController)?,
        router: (any Router)?
    ) {
        self.wallet = wallet
        self.makeWalletSheet = makeWalletSheet
        self.router = router
        super.init()
        guard let wallet else { return }
        badge.isUserInteractionEnabled = makeWalletSheet != nil
        badge.addAction(
            UIAction { [weak self] _ in self?.presentWalletSheet() },
            for: .primaryActionTriggered
        )
        // ⚠️ A GROWN COUNT NEEDS A FRESH WRAPPER: a bar measures a custom view
        // once, at install, so re-assigning the same item keeps the old width
        // and "120" wraps. See `WalletBadgeButton.onFittedWidthChange`.
        badge.onFittedWidthChange = { [weak self] in
            guard let self else { return }
            walletItem = makeWalletItem()
            apply()
        }
        // Kept on this object, so the observation goes with it — a pushed
        // screen's header dies with the screen, every pop.
        walletObservation = wallet.changes.observe { [weak self] in
            self?.walletDidChange()
        }
        walletItem = makeWalletItem()
        refresh()
    }

    /// Dresses `host`'s navigation item: no title, a bare chevron for anything
    /// pushed above it, and the trailing run. Call once, from `viewDidLoad` or
    /// earlier; the header re-applies itself when the badge changes width.
    public func install(on host: UIViewController) {
        self.host = host
        host.title = nil
        host.navigationItem.title = nil
        host.navigationItem.largeTitleDisplayMode = .never
        host.navigationItem.backButtonDisplayMode = .minimal
        apply()
    }

    /// ⚠️ `[0]` IS THE SCREEN EDGE: search keeps the corner, the balance sits
    /// inboard — the root's arrangement. Each in its own bubble: a shared glass
    /// pill would read the two as one segmented control.
    private func apply() {
        guard let host else { return }
        let items = [searchItem, walletItem].compactMap { $0 }
        for item in items { item.sharesBackground = false }
        // Through the toasts' door (#1420, #1679).
        host.setOwnTrailingBarItems(items, animated: false)
    }

    private func makeWalletItem() -> UIBarButtonItem {
        let item = BarItems.container(id: Self.walletItemIdentifier, view: badge)
        item.accessibilityLabel = "Likes balance"
        return item
    }

    nonisolated private func walletDidChange() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.walletDidChange() }
            return
        }
        MainActor.assumeIsolated { refresh() }
    }

    private func refresh() {
        guard let wallet else { return }
        let snapshot = wallet.snapshot()
        badge.update(
            balance: snapshot.balance,
            // A read-out must not advertise a claim the viewer cannot take here.
            claimAvailable: makeWalletSheet != nil && snapshot.claimAvailable,
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

    private func presentWalletSheet() {
        guard let host, host.presentedViewController == nil,
              let sheet = makeWalletSheet?() else { return }
        host.present(sheet, animated: true)
    }

    #if DEBUG
    /// The trailing run as the bar will read it, edge first — what a test
    /// pins instead of a screenshot.
    var debugTrailingIdentifiers: [String] {
        (host?.navigationItem.rightBarButtonItems ?? []).map { $0.identifier ?? "?" }
    }

    /// The count the balance badge draws.
    var debugRenderedBalance: String? { badge.renderedCount }
    #endif
}
