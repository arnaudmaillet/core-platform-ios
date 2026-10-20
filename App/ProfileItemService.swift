import CoreStorage
import Foundation
import Maps
import Profile

/// The gem-shop items a profile wears (#944, #947) — the shell's answer to
/// `ProfileItemAccess`.
///
/// - OWNERSHIP is the account's, bought once, for good, for every profile
///   of it: the server's catalogue items (`ListOwnedItems`, #1475) for a
///   member whose wallet is the server's, `ProfileItemStore` otherwise.
/// - The GEMS are the wallet's — the server's `PurchaseItem` for a member
///   (#1475), `WalletStore.spendGems` for the device's mock. Likes never buy
///   an item.
/// - A guest owns nothing and buys nothing; neither does a teen (#401).
@MainActor
final class ProfileItemService: ProfileItemAccess, ProfileItemSelling {
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

    var gems: Int { wallet.snapshot().gems }

    /// The Shop's Profile shelf: every item there is.
    var items: [ProfileItem] { ProfileItem.allCases }

    func owns(_ item: ProfileItem) -> Bool {
        guard isMember() else { return false }
        if wallet.isServerBacked { return wallet.ownedItems?.contains(item.catalogID) ?? false }
        return store.owns(item, accountID: accountID)
    }

    /// The catalogue's price, once read; the item's own until then.
    func price(of item: ProfileItem) -> Int {
        wallet.catalogPrice(of: item.catalogID) ?? item.gemPrice
    }

    func buy(_ item: ProfileItem) async -> ProfileItemPurchase {
        guard isMember(), !TeenProtections.shared.restrictsPurchases else { return .unavailable }
        guard !owns(item) else { return .alreadyOwned }
        if wallet.isServerBacked {
            let key = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            return ProfileItemPurchase(await wallet.purchaseItem(item.catalogID, price: price(of: item), idempotencyKey: key))
        }
        switch wallet.spendGems(item.gemPrice) {
        case .spent(let remaining):
            store.grant(item, to: accountID)
            return .bought(remainingGems: remaining)
        case .insufficient(let gems):
            return .insufficientGems(needed: item.gemPrice, have: gems)
        }
    }
}
