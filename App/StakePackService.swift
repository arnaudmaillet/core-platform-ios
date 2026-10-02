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

    var offer: StakePackOffer {
        StakePackOffer(
            shotsPerPack: WalletStore.Policy.StakePack.shots,
            pointsPerShot: WalletStore.Policy.StakePack.pointsPerShot,
            price: WalletStore.Policy.StakePack.price,
            shotsLeft: wallet.stakeShots
        )
    }

    func buyPack() -> StakePackPurchase {
        switch wallet.buyStakePack() {
        case .bought(let shots, let remainingGems): .bought(shots: shots, remainingGems: remainingGems)
        case .packStillActive(let shotsLeft): .packStillActive(shotsLeft: shotsLeft)
        case .insufficientGems(let needed, let have): .insufficientGems(needed: needed, have: have)
        }
    }
}
