import CoreStorage
import Foundation
import Maps

/// The Shop's ×100 cartridge pack over the wallet — the shell's answer to
/// `StakePackSelling`, as `CountryAccessService` is to `CountryAccess`.
///
/// The pack lives in `WalletStore` beside the gems that buy it and the points
/// its shots stake: one store, one persistence, one change post. Mock-only
/// today like the rest of the wallet; the real one is `wallet.v1`'s
/// `BuyStakePack` and `Wallet.stake_shots` (`BACKEND_VIRTUAL_CURRENCY.md`
/// §3.3), behind this same seam.
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
        return WalletStore.Policy.StakePack.tiers.map { tier in
            StakePackOffer(
                id: tier.id, shotsPerPack: tier.shots,
                pointsPerShot: WalletStore.Policy.StakePack.pointsPerShot,
                price: tier.price, shotsLeft: tier.id == loaded ? shotsLeft : 0
            )
        }
    }

    func buyPack() -> StakePackPurchase {
        buyPack(offer)
    }

    func buyPack(_ offer: StakePackOffer) -> StakePackPurchase {
        let tier = WalletStore.Policy.StakePack.tiers.first { $0.id == offer.id } ?? WalletStore.Policy.StakePack.standard
        return switch wallet.buyStakePack(tier) {
        case .bought(let shots, let remainingGems): .bought(shots: shots, remainingGems: remainingGems)
        case .packStillActive(let shotsLeft): .packStillActive(shotsLeft: shotsLeft)
        case .insufficientGems(let needed, let have): .insufficientGems(needed: needed, have: have)
        }
    }
}
