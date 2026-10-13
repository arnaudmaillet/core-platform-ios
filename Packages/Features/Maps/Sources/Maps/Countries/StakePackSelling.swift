import Foundation

/// The ×100 cartridge pack as the Shop sells it, at one instant.
///
/// A pack of SHOTS: each stakes `pointsPerShot` of the viewer's OWN points in
/// one tap, where a plain stake commits the default amount. Gems buy the
/// convenience, never points (charter V5.3 §34: B never becomes A).
public struct StakePackOffer: Equatable, Sendable, Identifiable {
    /// Which pack (backend #941: `pack_id`).
    public let id: String
    /// Shots in a fresh pack.
    public let shotsPerPack: Int
    /// Points one shot stakes.
    public let pointsPerShot: Int
    /// What a pack costs, in gems.
    public let price: Int
    /// Shots left in THIS pack: 0 unless it is the one loaded.
    public let shotsLeft: Int

    public init(id: String = "shots_3", shotsPerPack: Int, pointsPerShot: Int, price: Int, shotsLeft: Int) {
        self.id = id
        self.shotsPerPack = shotsPerPack
        self.pointsPerShot = pointsPerShot
        self.price = price
        self.shotsLeft = shotsLeft
    }

    /// Packs don't stack: a new one only once the current one is empty.
    public var isActive: Bool { shotsLeft > 0 }
}

/// What buying a pack did.
public enum StakePackPurchase: Equatable, Sendable {
    case bought(shots: Int, remainingGems: Int)
    case packStillActive(shotsLeft: Int)
    case insufficientGems(needed: Int, have: Int)
}

/// The Shop's Boosts section: the ×100 cartridge pack, and buying it with gems.
///
/// Answered by the shell over the wallet (`WalletStore.buyStakePack`), like
/// `CountryAccess` over the unlocks — the Maps feature never sees the store.
@MainActor
public protocol StakePackSelling: AnyObject {
    /// The pack, as of now.
    var offer: StakePackOffer { get }
    func buyPack() -> StakePackPurchase
    /// Every pack on sale, smallest first (backend #941). Packs don't stack:
    /// while one is loaded, none can be bought.
    var offers: [StakePackOffer] { get }
    func buyPack(_ offer: StakePackOffer) -> StakePackPurchase
}

public extension StakePackSelling {
    var offers: [StakePackOffer] { [offer] }
    func buyPack(_ offer: StakePackOffer) -> StakePackPurchase { buyPack() }
}

public extension Notification.Name {
    /// Posted by a `StakePackSelling` when the pack or the gems changed.
    static let stakePackDidChange = Notification.Name("stakePack.didChange")
}
