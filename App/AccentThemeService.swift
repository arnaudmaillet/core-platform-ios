import CoreStorage
import DesignSystem
import Foundation
import Maps

/// The accent themes the Shop sells (#1379) — the shell's answer to
/// `ThemeSelling`.
///
/// - OWNERSHIP is the account's: the catalogue item id (`theme.violet`) in
///   `ProfileItemStore`, the inventory as `ListOwnedItems` gives it. Pink is
///   free, so every account owns it.
/// - The GEMS are the wallet's (`WalletStore.spendGems`).
/// - APPLYING is a device setting per account (`AccentThemePreference`).
/// - A guest owns nothing beyond pink and buys nothing; neither does a teen
///   (#401).
///
/// Mock mode only, as the rest of the Shop is, until the gems' source is
/// decided (#1475): the fleet's `PurchaseItem` debits the server's gems.
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

    init(
        accountID: String, wallet: WalletStore, store: ProfileItemStore,
        isMember: @escaping @MainActor () -> Bool = { true }
    ) {
        self.accountID = accountID
        self.wallet = wallet
        self.store = store
        self.isMember = isMember
    }

    var offers: [ThemeOffer] { Self.catalogue }

    var applied: AccentTheme { AccentThemePreference.applied }

    func owns(_ theme: AccentTheme) -> Bool {
        isMember() ? isOwned(theme, by: accountID) : isFree(theme)
    }

    /// Whether `accountID` owns `theme` on this device: a free one always —
    /// what a launch checks before it draws in the stored theme.
    func isOwned(_ theme: AccentTheme, by accountID: String) -> Bool {
        isFree(theme) || store.owns(itemID: theme.itemID, accountID: accountID)
    }

    private func isFree(_ theme: AccentTheme) -> Bool {
        Self.catalogue.first(where: { $0.theme == theme })?.price == 0
    }

    func buy(_ theme: AccentTheme) -> ProfileItemPurchase {
        guard isMember(), !TeenProtections.shared.restrictsPurchases,
              let offer = Self.catalogue.first(where: { $0.theme == theme }) else { return .unavailable }
        guard !owns(theme) else { return .alreadyOwned }
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
