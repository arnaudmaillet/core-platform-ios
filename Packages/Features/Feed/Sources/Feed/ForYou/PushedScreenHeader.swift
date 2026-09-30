import CoreNavigation
import CoreStorage
import DesignSystem
import UIKit

/// The header every screen For You PUSHES wears: `[‹] ———— [points][search]`
/// over the screen's name as a LARGE title.
///
/// ```
///   ‹                               (123) 🔍
///   Following                                  ← large title, collapses on scroll
/// ```
///
/// The name is a large title (product call, 2026-09-30, reversing #311's "no
/// title"): "Following", "Friends", and "For you" over the mosaic "View all"
/// pushes. In the bar's own row it would compete with the chevron and the
/// trailing run; below it, it is the page's heading, and it folds into the bar
/// as the list scrolls. The trailing run is the root's own, in the root's
/// order — the balance inboard, search at the edge — so the two items read as
/// the same controls carried one level in rather than as a second header.
///
/// ⚠️ A LARGE TITLE NEEDS THE BAR TO ALLOW ONE. `.always` is only honoured by
/// a bar with `prefersLargeTitles`, which For You's stack turns on before it
/// pushes one of these (`allowLargeTitles(on:)`). Everything else that can
/// land on that stack says `.never` for itself — For You, a profile and its
/// relationship lists, the snap feed, search and its results, the post page,
/// a conversation thread, a place page — because an item left `.automatic`
/// INHERITS the item under it, and a feed pushed from a large-titled list
/// would otherwise open under a tall large-title bar reading "Timeline"
/// (audited against every `RouteResolver` route and every push these screens
/// make, 2026-09-30). A new screen that can be pushed there must say `.never`
/// too.
///
/// # Why it is an object, and why it is not the shell's installer
///
/// The shell's `WalletBadgeInstaller` owns the root headers' badge and hangs
/// one on a pushed PROFILE through the router. These screens are pushed by For
/// You itself, inside this package, where the shell's type cannot be reached —
/// the place page and the post screen are in the same position and build their
/// badge locally for the same reason. What the installer exists to share is
/// the freshness rules, and they are small: a store observer, a claim-unlock
/// wake-up, and a FRESH item whenever the count changes width. Written once
/// here, three screens use it (Discover's whole mosaic, and the Friends and
/// Following lists), and each holds its own — a badge is a view, and a view
/// lives in one bar.
///
/// ⚠️ THE BAR ITEMS CARRY THE ROOT'S IDENTIFIERS. iOS 26 treats two items with
/// one identifier as ONE item across a push, so the balance and search stay in
/// place while the rest of the bar transitions, instead of cross-fading two
/// copies of the same controls. The balance's is the shell's own
/// (`WalletBadgeInstaller.itemIdentifier` — spelled out again here because the
/// App target cannot be imported); search's is shared with
/// `ForYouViewController.searchItem`.
///
/// Native chrome is UIKit's (`TabBarRevealPolicy`): these screens hide the tab
/// bar with `hidesBottomBarWhenPushed` and write nothing on any bar.
@MainActor
final class PushedScreenHeader: NSObject {
    /// The balance item's identifier — the shell's `WalletBadgeInstaller
    /// .itemIdentifier`, which every root header's badge carries.
    static let walletItemIdentifier = "shell.wallet-balance"
    /// Search's, shared with For You's own search item.
    static let searchItemIdentifier = "foryou.search"

    private let wallet: WalletStore?
    private let makeWalletSheet: (@MainActor () -> UIViewController)?
    private weak var router: (any Router)?
    private weak var host: UIViewController?

    private let badge = WalletBadgeButton()
    private var walletItem: UIBarButtonItem?
    /// Wakes the badge when the hourly claim unlocks — the one state change
    /// that arrives by CLOCK, so no store notification announces it.
    private var claimUnlockTimer: Timer?

    private(set) lazy var searchItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "magnifyingglass"),
            primaryAction: UIAction { [weak self] _ in self?.router?.route(to: .search) }
        )
        item.accessibilityLabel = "Search"
        item.identifier = Self.searchItemIdentifier
        return item
    }()

    /// - Parameters:
    ///   - wallet: the app's ONE store (`WalletStore`'s change post is scoped
    ///     to the instance). Nil leaves the header with search alone.
    ///   - makeWalletSheet: the shell's claim sheet. Nil makes the badge a
    ///     read-out: a control with nothing behind it is not offered.
    init(
        wallet: WalletStore?,
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
        // Selector-based, so the registration goes with this object — a pushed
        // screen's header dies with the screen, every pop.
        NotificationCenter.default.addObserver(
            self, selector: #selector(walletDidChange),
            name: WalletStore.didChangeNotification, object: wallet
        )
        walletItem = makeWalletItem()
        refresh()
    }

    /// Dresses `host`'s navigation item: `title` as a large title, a bare
    /// chevron for anything pushed above it, and the trailing run. Call once,
    /// from `viewDidLoad` or earlier; the header re-applies itself when the
    /// badge changes width.
    func install(on host: UIViewController, title: String) {
        self.host = host
        host.navigationItem.title = title
        host.navigationItem.largeTitleDisplayMode = .always
        // The chevron of whatever is pushed from here stays bare — the budget
        // every pushed bar was measured against (`ForYouViewController`).
        host.navigationItem.backButtonDisplayMode = .minimal
        apply()
    }

    /// Lets `navigationController`'s bar draw large titles at all — asked by
    /// For You before it pushes a screen wearing this header. Idempotent, and
    /// never turned back off: every other item on the stack states `.never`
    /// (see the type's note), so the preference only shows where an item asks
    /// for it.
    static func allowLargeTitles(on navigationController: UINavigationController) {
        guard !navigationController.navigationBar.prefersLargeTitles else { return }
        navigationController.navigationBar.prefersLargeTitles = true
    }

    /// ⚠️ `[0]` IS THE SCREEN EDGE: search keeps the corner, the balance sits
    /// inboard — the root's arrangement. Each in its own bubble: a shared glass
    /// pill would read the two as one segmented control.
    private func apply() {
        guard let host else { return }
        let items = [searchItem, walletItem].compactMap { $0 }
        for item in items { item.sharesBackground = false }
        host.navigationItem.rightBarButtonItems = items
    }

    private func makeWalletItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(customView: badge)
        item.identifier = Self.walletItemIdentifier
        item.accessibilityLabel = "Points balance"
        return item
    }

    @objc nonisolated private func walletDidChange() {
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
    #endif
}
