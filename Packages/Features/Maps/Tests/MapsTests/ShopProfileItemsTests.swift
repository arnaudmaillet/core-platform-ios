import CoreStorage
import DesignSystem
import MapsInterface
import Testing
import UIKit
@testable import Maps

/// The Shop's Profile shelf (#944): the video banner at 500 gems, bought once
/// for good, then shown as owned.
@MainActor
struct ShopProfileItemsTests {
    private final class Access: CountryAccess {
        let homeCountry: String? = "FR"
        var currentCountry: String? = nil
        var gems = 600
        var purchasesRestricted = false
        func isUnlocked(_ code: String) -> Bool { code == "FR" }
        func standing(of code: String) -> CountryStanding? { nil }
        func standings() -> [CountryStanding] { [] }
        func unlock(_ code: String) -> CountryUnlockOutcome { .unknownCountry }
    }

    private final class Items: ProfileItemSelling {
        let access: Access
        var owned: Set<ProfileItem> = []
        init(access: Access) { self.access = access }
        var items: [ProfileItem] { [.videoBanner] }
        func owns(_ item: ProfileItem) -> Bool { owned.contains(item) }
        func buy(_ item: ProfileItem) -> ProfileItemPurchase {
            guard !owned.contains(item) else { return .alreadyOwned }
            guard access.gems >= item.gemPrice else { return .insufficientGems(needed: item.gemPrice, have: access.gems) }
            access.gems -= item.gemPrice
            owned.insert(item)
            return .bought(remainingGems: access.gems)
        }
    }

    private func front(_ access: Access, items: Items?) -> (ShopStorefrontViewController, UINavigationController) {
        let front = ShopStorefrontViewController(access: access, stakePacks: nil, profileItems: items)
        let navigation = UINavigationController(rootViewController: front)
        navigation.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        navigation.view.layoutIfNeeded()
        front.view.layoutIfNeeded()
        return (front, navigation)
    }

    @Test func noSellerNoProfileShelf() {
        let (front, _) = front(Access(), items: nil)
        #expect(front.profileShelf == nil)
    }

    /// Its own shelf, before the countries, with the item's price.
    @Test func theVideoBannerIsOnTheProfileShelfAtItsPrice() throws {
        let access = Access()
        let (front, _) = front(access, items: Items(access: access))
        let shelf = try #require(front.profileShelf)
        #expect(shelf.heading.debugTitleText == "Profile")
        let card = try #require(front.itemCards.first)
        #expect(card.item == .videoBanner && !card.owned)
        #expect(card.accessibilityValue == "500 gems")
        let countries = try #require(front.countriesShelf)
        #expect(shelf.frame.maxY <= countries.frame.minY)
    }

    /// Bought, the card says Owned and the gems are spent; a second buy
    /// spends nothing.
    @Test func buyingTurnsTheCardOwned() throws {
        let access = Access()
        let items = Items(access: access)
        let (front, _) = front(access, items: items)
        #expect(front.buyItem(.videoBanner) == .bought(remainingGems: 100))
        front.rebuild()
        let card = try #require(front.itemCards.first)
        #expect(card.owned)
        #expect(card.accessibilityValue == "Owned")
        #expect(front.buyItem(.videoBanner) == .alreadyOwned)
        #expect(access.gems == 100)
    }

    /// Short of gems, the confirmation is disabled with how many are missing.
    @Test func shortOfGemsTheBuyIsDisabledAndSaysWhy() throws {
        let access = Access()
        access.gems = 82
        let (front, _) = front(access, items: Items(access: access))
        let menu = front.itemMenu(.videoBanner, owned: false)
        let buy = try #require(menu.children.first as? UIAction)
        #expect(buy.attributes.contains(.disabled))
        #expect(buy.subtitle == "418 more gems needed")
    }

    /// Owned, the menu says where it is used, and buys nothing.
    @Test func ownedTheMenuSaysWhereItIsUsed() throws {
        let (front, _) = front(Access(), items: nil)
        let menu = front.itemMenu(.videoBanner, owned: true)
        let row = try #require(menu.children.first as? UIAction)
        #expect(row.attributes.contains(.disabled))
        #expect(row.subtitle == "Choose its video in Edit Profile")
    }
}
