import CoreStorage
import DesignSystem
import Foundation

/// The Shop items a gem goal weighs (#1480): what is bought once and kept —
/// the profile items and the accent themes — in the Shop's order. Countries
/// and boosts are not goals: a country is opened, a pack used up.
public enum ShopGoalItems {
    @MainActor
    public static func items(
        profileItems: (any ProfileItemSelling)?, themes: (any ThemeSelling)?
    ) -> [WalletGemGoal.Item] {
        let profile = (profileItems?.items ?? []).map { item in
            WalletGemGoal.Item(
                id: item.rawValue, name: "the \(item.shopTitle.lowercased())",
                price: profileItems?.price(of: item) ?? item.gemPrice, owned: profileItems?.owns(item) ?? false
            )
        }
        let accents = (themes?.offers ?? []).map { offer in
            WalletGemGoal.Item(
                id: offer.theme.itemID, name: "the \(offer.theme.title) theme",
                price: offer.price, owned: themes?.owns(offer.theme) ?? false
            )
        }
        return profile + accents
    }
}
