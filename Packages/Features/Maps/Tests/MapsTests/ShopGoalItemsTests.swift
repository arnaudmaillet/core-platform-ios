import CoreStorage
import DesignSystem
import Testing
@testable import Maps

/// The gem goal's candidates (#1480): the profile items, by their Shop
/// names. The accent themes were candidates too, until they were retired
/// (#2062).
@MainActor
struct ShopGoalItemsTests {
    private final class Items: ProfileItemSelling {
        var owned: Set<ProfileItem> = []
        var items: [ProfileItem] { [.videoBanner] }
        func owns(_ item: ProfileItem) -> Bool { owned.contains(item) }
        func buy(_ item: ProfileItem) async -> ProfileItemPurchase { .unavailable }
    }

    @Test func theCandidatesAreTheProfileItems() {
        let items = ShopGoalItems.items(profileItems: Items())
        #expect(items.map(\.id) == ["video-banner"])
        #expect(items.map(\.name) == ["the video banner"])
        #expect(items.map(\.owned) == [false])
        let goal = WalletGemGoal.goal(among: items, gems: 180)
        #expect(goal?.item.id == "video-banner")
        #expect(goal?.missing == 320)
    }

    @Test func noSellersNoCandidates() {
        #expect(ShopGoalItems.items(profileItems: nil).isEmpty)
    }
}
