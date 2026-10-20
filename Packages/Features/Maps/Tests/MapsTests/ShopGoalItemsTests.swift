import CoreStorage
import DesignSystem
import Testing
@testable import Maps

/// The gem goal's candidates (#1480): the profile items and the themes, by
/// their Shop names.
@MainActor
struct ShopGoalItemsTests {
    private final class Items: ProfileItemSelling {
        var owned: Set<ProfileItem> = []
        var items: [ProfileItem] { [.videoBanner] }
        func owns(_ item: ProfileItem) -> Bool { owned.contains(item) }
        func buy(_ item: ProfileItem) -> ProfileItemPurchase { .unavailable }
    }

    private final class Themes: ThemeSelling {
        var owned: Set<AccentTheme> = [.pink]
        var applied: AccentTheme = .pink
        var offers: [ThemeOffer] {
            [ThemeOffer(theme: .pink, price: 0), ThemeOffer(theme: .violet, price: 50), ThemeOffer(theme: .red, price: 50)]
        }
        func owns(_ theme: AccentTheme) -> Bool { owned.contains(theme) }
        func buy(_ theme: AccentTheme) -> ProfileItemPurchase { .unavailable }
        func apply(_ theme: AccentTheme) {}
    }

    @Test func theCandidatesAreTheProfileItemsAndTheThemes() {
        let themes = Themes()
        themes.owned.insert(.red)
        let items = ShopGoalItems.items(profileItems: Items(), themes: themes)
        #expect(items.map(\.id) == ["video-banner", "theme.pink", "theme.violet", "theme.red"])
        #expect(items.map(\.name) == ["the video banner", "the Pink theme", "the Violet theme", "the Red theme"])
        #expect(items.map(\.owned) == [false, true, false, true])
        // 180 gems, Violet in reach: the banner is the goal.
        let goal = WalletGemGoal.goal(among: items, gems: 180)
        #expect(goal?.item.id == "video-banner")
        #expect(goal?.missing == 320)
    }

    @Test func noSellersNoCandidates() {
        #expect(ShopGoalItems.items(profileItems: nil, themes: nil).isEmpty)
    }
}
