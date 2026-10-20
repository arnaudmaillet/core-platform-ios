import Foundation

/// The hub's gem goal (#1480): which Shop item the viewer's gems are headed
/// for.
///
/// The CHEAPEST item not owned that costs MORE than the balance — "320 more
/// for the video banner" — so the goal is always the nearest thing still out
/// of reach. When everything not owned is already in reach, the cheapest of
/// those, to be bought now. Nothing left to buy: no goal.
///
/// Kept beside `WalletStore`, as `WalletStakeDays` is, because the App target
/// has no unit-test target.
public enum WalletGemGoal {
    /// A Shop item as the goal weighs it.
    public struct Item: Equatable, Sendable {
        /// The catalogue's id (`theme.violet`, `video-banner`).
        public let id: String
        /// Its name in a sentence: "the video banner".
        public let name: String
        public let price: Int
        public let owned: Bool

        public init(id: String, name: String, price: Int, owned: Bool) {
            self.id = id
            self.name = name
            self.price = price
            self.owned = owned
        }
    }

    /// The goal, and how far the balance is from it.
    public struct Goal: Equatable, Sendable {
        public let item: Item
        /// Gems still needed; 0 when it can be bought now.
        public let missing: Int

        public var isAffordable: Bool { missing == 0 }
    }

    /// The goal among `items` for `gems`; nil when nothing is left to buy.
    /// Free items are never a goal. Ties go to the first in `items`' order.
    public static func goal(among items: [Item], gems: Int) -> Goal? {
        let forSale = items.filter { !$0.owned && $0.price > 0 }
        if let nearest = cheapest(forSale.filter { $0.price > gems }) {
            return Goal(item: nearest, missing: nearest.price - gems)
        }
        return cheapest(forSale).map { Goal(item: $0, missing: 0) }
    }

    private static func cheapest(_ items: [Item]) -> Item? {
        items.enumerated().min { lhs, rhs in
            lhs.element.price != rhs.element.price ? lhs.element.price < rhs.element.price : lhs.offset < rhs.offset
        }?.element
    }
}
