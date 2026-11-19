import CoreStorage
import Foundation
import WalletInterface

/// The Shop's ×100 cartridge pack over the wallet — the shell's answer to
/// `StakePackSelling`, as `CountryAccessService` is to `CountryAccess`.
///
/// The pack lives in `WalletStore` beside the gems that buy it and the points
/// its shots stake: one store, one persistence, one change signal. A member's
/// pack is the server's (#1475): `wallet.v1`'s `BuyStakePack`, its packs on
/// sale and `Wallet.stake_shots`; a guest's is the device's mock.
@MainActor
public final class StakePackService: StakePackSelling {
    private let wallet: WalletStore
    /// What `observeChanges` hands out: relayed from the wallet, on main.
    private let changes = StoreChanges<Void>()
    private var walletObservation: StoreObservation?

    public init(wallet: WalletStore) {
        self.wallet = wallet
        // A shot fired in the feed, a pack bought, gems earned: the shop
        // re-reads on any of them.
        walletObservation = wallet.changes.observe(on: .main) { [changes] in
            changes.send()
        }
    }

    public func observeChanges(_ handler: @escaping @MainActor @Sendable () -> Void) -> StoreObservation {
        changes.observeOnMain { handler() }
    }

    /// The pack loaded, or the standard one when none is.
    public var offer: StakePackOffer {
        let all = offers
        return all.first(where: \.isActive) ?? all[0]
    }

    public var offers: [StakePackOffer] {
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

    public func buyPack() async -> StakePackPurchase {
        await buyPack(offer)
    }

    public func buyPack(_ offer: StakePackOffer) async -> StakePackPurchase {
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
