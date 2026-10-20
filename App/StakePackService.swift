import CoreStorage
import Foundation
import Maps

/// The Shop's ×100 cartridge pack over the wallet — the shell's answer to
/// `StakePackSelling`, as `CountryAccessService` is to `CountryAccess`.
///
/// The pack lives in `WalletStore` beside the gems that buy it and the points
/// its shots stake: one store, one persistence, one change post. A member's
/// pack is the server's (#1475): `wallet.v1`'s `BuyStakePack`, its packs on
/// sale and `Wallet.stake_shots`; a guest's is the device's mock.
@MainActor
final class StakePackService: StakePackSelling {
    private let wallet: WalletStore
    private var observer: NSObjectProtocol?

    init(wallet: WalletStore) {
        self.wallet = wallet
        // A shot fired in the feed, a pack bought, gems earned: the shop
        // re-reads on any of them.
        observer = NotificationCenter.default.addObserver(
            forName: WalletStore.didChangeNotification, object: wallet, queue: .main
        ) { _ in
            NotificationCenter.default.post(name: .stakePackDidChange, object: nil)
        }
    }

    /// The pack loaded, or the standard one when none is.
    var offer: StakePackOffer {
        let all = offers
        return all.first(where: \.isActive) ?? all[0]
    }

    var offers: [StakePackOffer] {
        let loaded = wallet.stakePackTierID
        let shotsLeft = wallet.stakeShots
        return wallet.stakePackTiers.map { tier in
            StakePackOffer(
                id: tier.id, shotsPerPack: tier.shots,
                likesPerShot: WalletStore.Policy.StakePack.likesPerShot,
                price: tier.price, shotsLeft: tier.id == loaded ? shotsLeft : 0
            )
        }
    }

    func buyPack() async -> StakePackPurchase {
        await buyPack(offer)
    }

    func buyPack(_ offer: StakePackOffer) async -> StakePackPurchase {
        let tier = wallet.stakePackTiers.first { $0.id == offer.id } ?? WalletStore.Policy.StakePack.standard
        // One key per purchase: a retry the server already answered charges
        // nothing more.
        let key = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return switch await wallet.buyStakePack(tier, idempotencyKey: key) {
        case .bought(let shots, let remainingGems): .bought(shots: shots, remainingGems: remainingGems)
        case .packStillActive(let shotsLeft): .packStillActive(shotsLeft: shotsLeft)
        case .insufficientGems(let needed, let have): .insufficientGems(needed: needed, have: have)
        case .unavailable: .unavailable
        }
    }
}
