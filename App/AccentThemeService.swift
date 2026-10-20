import CoreStorage
import DesignSystem
import Foundation
import Maps

/// The accent themes the Shop sells (#1379) — the shell's answer to
/// `ThemeSelling`.
///
/// - OWNERSHIP is the account's catalogue item (`theme.violet`): the
///   server's (`ListOwnedItems`, #1475) for a member whose wallet is the
///   server's, `ProfileItemStore` otherwise. Pink is free, so every account
///   owns it.
/// - The GEMS are the wallet's: the server's `PurchaseItem` for a member
///   (#1475), `WalletStore.spendGems` for the device's mock.
/// - APPLYING is a device setting per account (`AccentThemePreference`).
/// - A guest owns nothing beyond pink and buys nothing; neither does a teen
///   (#401).
@MainActor
final class AccentThemeService: ThemeSelling {
    /// The catalogue's prices (the wallet service's default `WALLET_CATALOG`,
    /// backend #892), pink first.
    static let catalogue: [ThemeOffer] = [
        ThemeOffer(theme: .pink, price: 0),
        ThemeOffer(theme: .violet, price: 50),
        ThemeOffer(theme: .red, price: 50),
    ]

    private let accountID: String
    private let wallet: WalletStore
    private let store: ProfileItemStore
    private let isMember: @MainActor () -> Bool
    private var observer: NSObjectProtocol?

    init(
        accountID: String, wallet: WalletStore, store: ProfileItemStore,
        isMember: @escaping @MainActor () -> Bool = { true }
    ) {
        self.accountID = accountID
        self.wallet = wallet
        self.store = store
        self.isMember = isMember
        // The server's list of what the account owns lands after launch:
        // the applied theme is checked against it then.
        observer = NotificationCenter.default.addObserver(
            forName: WalletStore.didChangeNotification, object: wallet, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.revalidate() }
        }
    }

    /// The shelf at the catalogue's prices, once read (#1475).
    var offers: [ThemeOffer] {
        Self.catalogue.map { ThemeOffer(theme: $0.theme, price: wallet.catalogPrice(of: $0.theme.itemID) ?? $0.price) }
    }

    var applied: AccentTheme { AccentThemePreference.applied }

    func owns(_ theme: AccentTheme) -> Bool {
        isMember() ? isOwned(theme, by: accountID) : isFree(theme)
    }

    /// Whether `accountID` owns `theme` on this device: a free one always —
    /// what a launch checks before it draws in the stored theme.
    func isOwned(_ theme: AccentTheme, by accountID: String) -> Bool {
        if isFree(theme) { return true }
        if wallet.isServerBacked {
            // Not listed yet: the stored choice stands until the server says
            // otherwise (`revalidate`).
            return wallet.ownedItems?.contains(theme.itemID) ?? true
        }
        return store.owns(itemID: theme.itemID, accountID: accountID)
    }

    private func isFree(_ theme: AccentTheme) -> Bool {
        offers.first(where: { $0.theme == theme })?.price == 0
    }

    /// Once the server has listed what the account owns: a theme applied that
    /// it does not own (a refund, another account's) goes back to pink.
    func revalidate() {
        guard wallet.isServerBacked, wallet.ownedItems != nil else { return }
        let theme = AccentThemePreference.applied
        guard !isOwned(theme, by: accountID) else { return }
        AccentThemePreference.setTheme(.pink, for: accountID)
        AccentThemePreference.apply(.pink)
    }

    func buy(_ theme: AccentTheme) async -> ProfileItemPurchase {
        guard isMember(), !TeenProtections.shared.restrictsPurchases,
              let offer = offers.first(where: { $0.theme == theme }) else { return .unavailable }
        guard !owns(theme) else { return .alreadyOwned }
        if wallet.isServerBacked {
            let key = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            return ProfileItemPurchase(await wallet.purchaseItem(theme.itemID, price: offer.price, idempotencyKey: key))
        }
        switch wallet.spendGems(offer.price) {
        case .spent(let remaining):
            store.grant(itemID: theme.itemID, to: accountID)
            return .bought(remainingGems: remaining)
        case .insufficient(let gems):
            return .insufficientGems(needed: offer.price, have: gems)
        }
    }

    func apply(_ theme: AccentTheme) {
        guard owns(theme) else { return }
        AccentThemePreference.setTheme(theme, for: accountID)
        AccentThemePreference.apply(theme)
    }
}
