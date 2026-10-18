import CoreStorage
import Foundation
import Maps
import Profile

/// The gem-shop items a profile wears (#944, #947) — the shell's answer to
/// `ProfileItemAccess`.
///
/// - OWNERSHIP is the account's (`ProfileItemStore`, keyed by account id,
///   never by profile): bought once, for good, for every profile of it.
/// - The GEMS are the wallet's (`WalletStore.spendGems`) — points never buy
///   an item.
/// - A guest owns nothing and buys nothing; neither does a teen (#401).
///
/// Mock mode only until the backend carries ownership
/// (core-platform-backend#915, under #892).
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
        isMember() && store.owns(item, accountID: accountID)
    }

    func buy(_ item: ProfileItem) -> ProfileItemPurchase {
        guard isMember(), !TeenProtections.shared.restrictsPurchases else { return .unavailable }
        guard !owns(item) else { return .alreadyOwned }
        switch wallet.spendGems(item.gemPrice) {
        case .spent(let remaining):
            store.grant(item, to: accountID)
            return .bought(remainingGems: remaining)
        case .insufficient(let gems):
            return .insufficientGems(needed: item.gemPrice, have: gems)
        }
    }
}
