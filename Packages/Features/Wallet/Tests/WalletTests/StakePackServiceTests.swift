import CoreStorage
import Foundation
import Testing
import WalletInterface
@testable import Wallet

/// The Shop's Boosts, as the wallet sells them (#2385). This seller lived in
/// App, which has no unit-test target, so nothing pinned it before the move.
@MainActor
@Suite(.serialized)
struct StakePackServiceTests {
    /// Every wallet this suite makes, kept for the process.
    private static var wallets: [WalletStore] = []

    private static func freshWallet() -> WalletStore {
        let wallet = WalletStore(
            defaults: UserDefaults(suiteName: "stake-pack-\(UUID().uuidString)")!,
            scope: StorageScope(owner: .member(account: "account-1", profile: "profile-1"))
        )
        wallets.append(wallet)
        return wallet
    }

    /// One offer per tier of the catalogue, at the wallet's prices. With no
    /// pack loaded, none has shots left, and the offer shown is the first.
    @Test func everyTierIsOfferedAndNoneHasShotsWithoutAPack() {
        let wallet = Self.freshWallet()
        let seller = StakePackService(wallet: wallet)

        let offers = seller.offers
        #expect(offers.map(\.id) == wallet.stakePackTiers.map(\.id))
        #expect(offers.map(\.price) == wallet.stakePackTiers.map(\.price))
        #expect(offers.map(\.shotsPerPack) == wallet.stakePackTiers.map(\.shots))
        #expect(offers.allSatisfy { $0.shotsLeft == 0 && !$0.isActive })
        #expect(offers.allSatisfy { $0.likesPerShot == WalletStore.Policy.StakePack.likesPerShot })
        #expect(seller.offer == offers.first)
    }

    /// A change of this wallet tells the Shop to read its offers again; a
    /// change of another wallet does not.
    @Test func aChangeOfItsWalletReachesTheShop() async {
        let wallet = Self.freshWallet()
        let seller = StakePackService(wallet: wallet)
        @MainActor final class Heard { var count = 0 }
        let heard = Heard()
        let observation = seller.observeChanges { heard.count += 1 }

        Self.freshWallet().changes.send()
        wallet.changes.send()
        #expect(heard.count == 1)

        // Over once the Shop lets the observation go.
        observation.cancel()
        wallet.changes.send()
        #expect(heard.count == 1)
        withExtendedLifetime(seller) {}
    }
}
