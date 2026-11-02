import Testing
@testable import CoreStorage

/// The hub's gem goal (#1480).
struct WalletGemGoalTests {
    private static let gold = WalletGemGoal.Item(id: "frame.gold", name: "the gold frame", price: 50, owned: false)
    private static let neon = WalletGemGoal.Item(id: "frame.neon", name: "the neon frame", price: 50, owned: false)
    private static let banner = WalletGemGoal.Item(id: "video-banner", name: "the video banner", price: 500, owned: false)
    private static let free = WalletGemGoal.Item(id: "loader.wave", name: "the wave loader", price: 0, owned: true)

    private static func owned(_ item: WalletGemGoal.Item) -> WalletGemGoal.Item {
        WalletGemGoal.Item(id: item.id, name: item.name, price: item.price, owned: true)
    }

    /// The cheapest item still out of reach, and how far: 180 gems, the
    /// frames in reach, the banner is the goal.
    @Test func theGoalIsTheCheapestItemOutOfReach() {
        let goal = WalletGemGoal.goal(among: [Self.free, Self.gold, Self.neon, Self.banner], gems: 180)
        #expect(goal?.item == Self.banner)
        #expect(goal?.missing == 320)
        #expect(goal?.isAffordable == false)
    }

    /// Below every price, the cheapest one; ties go to the first listed.
    @Test func belowEveryPriceTheCheapestFirstListed() {
        let goal = WalletGemGoal.goal(among: [Self.banner, Self.gold, Self.neon], gems: 12)
        #expect(goal?.item == Self.gold)
        #expect(goal?.missing == 38)
    }

    /// Everything not owned in reach: the cheapest, to be bought now.
    @Test func everythingInReachTheCheapestNow() {
        let goal = WalletGemGoal.goal(among: [Self.owned(Self.banner), Self.neon, Self.gold], gems: 900)
        #expect(goal?.item == Self.neon)
        #expect(goal?.isAffordable == true)
    }

    /// After a purchase, the goal moves on.
    @Test func aPurchaseMovesTheGoalOn() {
        let before = WalletGemGoal.goal(among: [Self.gold, Self.banner], gems: 30)
        #expect(before?.item == Self.gold)
        let after = WalletGemGoal.goal(among: [Self.owned(Self.gold), Self.banner], gems: 0)
        #expect(after?.item == Self.banner)
        #expect(after?.missing == 500)
    }

    /// An item at exactly the balance is in reach, not a goal to save for.
    @Test func anItemAtTheBalanceIsInReach() {
        let goal = WalletGemGoal.goal(among: [Self.gold, Self.banner], gems: 50)
        #expect(goal?.item == Self.banner)
        #expect(goal?.missing == 450)
    }

    /// Everything owned, or only free items: no goal.
    @Test func nothingLeftToBuyNoGoal() {
        #expect(WalletGemGoal.goal(among: [Self.free, Self.owned(Self.gold)], gems: 10) == nil)
        #expect(WalletGemGoal.goal(among: [], gems: 10) == nil)
    }
}
