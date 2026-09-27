import DesignSystem
import MapsInterface
import Testing
import UIKit
@testable import Maps

/// The Shop: one list — the progress block, then Unlocked and Locked — under
/// a bar with the gems on the left and a close button on the right.
@MainActor
struct CountryShopViewControllerTests {
    /// Seven real countries, busiest first. France is home; the US and Spain
    /// were bought.
    private final class FakeAccess: CountryAccess {
        let homeCountry = "FR"
        var gems = 40
        var unlocked: Set<String> = ["FR", "US", "ES"]
        let all: [CountryStanding] = ["US", "CN", "IN", "ES", "FR", "DE", "IT"].enumerated().map { index, code in
            CountryStanding(
                code: code, rank: index + 1, likes: 1_000, posts: 10,
                price: code == "FR" ? 0 : CountryStanding.price(forRank: index + 1)
            )
        }

        func isUnlocked(_ code: String) -> Bool { unlocked.contains(code) }
        func standing(of code: String) -> CountryStanding? { all.first { $0.code == code } }
        // Deliberately NOT busiest first: the shop orders by rank itself.
        func standings() -> [CountryStanding] { all.reversed() }
        func unlock(_ code: String) -> CountryUnlockOutcome {
            unlocked.insert(code)
            NotificationCenter.default.post(name: .countryAccessDidChange, object: self)
            return .unlocked(remainingGems: gems)
        }
    }

    private func makeShop(_ access: FakeAccess = FakeAccess()) -> CountryShopViewController {
        let shop = CountryShopViewController(access: access)
        shop.loadViewIfNeeded()
        return shop
    }

    private func codes(_ shop: CountryShopViewController, in section: CountryShopViewController.Section) -> [String] {
        let snapshot = shop.dataSource.snapshot()
        guard snapshot.sectionIdentifiers.contains(section) else { return [] }
        return snapshot.itemIdentifiers(inSection: section).compactMap {
            if case .country(let code) = $0 { code } else { nil }
        }
    }

    private func search(_ shop: CountryShopViewController, _ text: String) {
        let controller = UISearchController(searchResultsController: nil)
        controller.searchBar.text = text
        shop.updateSearchResults(for: controller)
    }

    @Test func theProgressBlockLeadsThenUnlockedThenLocked() {
        let shop = makeShop()
        let snapshot = shop.dataSource.snapshot()
        #expect(snapshot.sectionIdentifiers == [.progress, .unlocked, .locked])
        #expect(snapshot.itemIdentifiers.first == .progress, "the progress block is the list's first item")
        #expect(snapshot.itemIdentifiers(inSection: .progress) == [.progress])
    }

    /// Home first, whatever its rank; then the rest by rank. Locked by rank.
    @Test func homeLeadsUnlockedAndBothSectionsFollowRank() {
        let shop = makeShop()
        #expect(codes(shop, in: .unlocked) == ["FR", "US", "ES"])
        #expect(codes(shop, in: .locked) == ["CN", "IN", "DE", "IT"])
        #expect(shop.headerTitle(for: .unlocked) == "Unlocked · 3")
        #expect(shop.headerTitle(for: .locked) == "Locked · 4")
        #expect(shop.headerTitle(for: .progress) == nil)
    }

    /// "an" is in France (unlocked) and Germany (locked): one search, both
    /// sections, each header counting its results.
    @Test func searchSpansBothSections() {
        let shop = makeShop()
        #expect(CountryAtlas.shared.country(code: "DE")?.name == "Germany")
        search(shop, "an")
        #expect(codes(shop, in: .unlocked) == ["FR"])
        #expect(codes(shop, in: .locked) == ["DE"])
        #expect(shop.headerTitle(for: .unlocked) == "Unlocked · 1")
        #expect(shop.headerTitle(for: .locked) == "Locked · 1")
        #expect(shop.dataSource.snapshot().itemIdentifiers.first == .progress)
        #expect(shop.contentUnavailableConfiguration == nil)

        // A section the search empties is dropped.
        search(shop, "chin")
        #expect(shop.dataSource.snapshot().sectionIdentifiers == [.progress, .locked])

        // Nothing at all is the system's search empty state.
        search(shop, "zzzz")
        #expect(shop.dataSource.snapshot().sectionIdentifiers == [.progress])
        #expect(shop.contentUnavailableConfiguration != nil)

        search(shop, "")
        #expect(codes(shop, in: .locked).count == 4)
        #expect(shop.contentUnavailableConfiguration == nil)
    }

    /// An unlock moves the row from Locked to Unlocked, in rank order.
    @Test func anUnlockMovesTheRowBetweenSections() {
        let access = FakeAccess()
        let shop = makeShop(access)
        _ = access.unlock("CN")
        #expect(codes(shop, in: .unlocked) == ["FR", "US", "CN", "ES"])
        #expect(codes(shop, in: .locked) == ["IN", "DE", "IT"])
        #expect(shop.headerTitle(for: .locked) == "Locked · 3")
    }

    @Test func theBarIsGemsLeftTitleShopCloseRight() throws {
        let shop = makeShop()
        #expect(shop.title == "Shop")
        #expect(shop.title == CountryShopEntry.title)

        let gems = try #require(shop.navigationItem.leftBarButtonItem)
        #expect(gems.identifier == CountryShopViewController.balanceItemIdentifier)
        #expect(gems.accessibilityLabel == "40 gems")
        let balance = try #require(gems.customView as? UIStackView)
        // The diamond is an IMAGE VIEW in the gem's own colour, never a text
        // attachment (glass draws those black).
        let diamond = try #require(balance.arrangedSubviews.first as? UIImageView)
        #expect(diamond.image?.renderingMode == .alwaysOriginal)
        #expect(diamond.tintColor == GemSymbol.tint)
        let count = try #require(balance.arrangedSubviews.last as? UILabel)
        #expect(count.text == "40")

        let close = try #require(shop.navigationItem.rightBarButtonItem)
        #expect(close.identifier == CountryShopViewController.closeItemIdentifier)
        #expect(close.primaryAction != nil)
        #expect(shop.navigationItem.rightBarButtonItems?.count == 1)
        #expect(shop.navigationItem.leftBarButtonItems?.count == 1)
    }

    /// The gems item is rebuilt, not mutated, when the balance moves.
    @Test func theGemsItemFollowsTheBalance() throws {
        let access = FakeAccess()
        let shop = makeShop(access)
        let before = shop.navigationItem.leftBarButtonItem
        access.gems = 1_250
        _ = access.unlock("IT")
        let after = try #require(shop.navigationItem.leftBarButtonItem)
        #expect(after !== before)
        #expect(after.identifier == CountryShopViewController.balanceItemIdentifier)
        #expect(after.accessibilityLabel == "1250 gems")
    }

    /// Opens collapsed, drags to full.
    @Test func theSheetOpensCollapsedAndGrowsToLarge() throws {
        let navigation = try #require(CountryShopViewController.sheet(access: FakeAccess()) as? UINavigationController)
        #expect(navigation.viewControllers.first is CountryShopViewController)
        #expect(navigation.modalPresentationStyle == .pageSheet)
        let sheet = try #require(navigation.sheetPresentationController)
        #expect(sheet.detents.map(\.identifier) == [.medium, .large])
        #expect(sheet.selectedDetentIdentifier == .medium)
        #expect(sheet.prefersScrollingExpandsWhenScrolledToEdge)
        #expect(sheet.prefersGrabberVisible)
    }

    /// The list is the whole sheet, and no effect is drawn under the bar.
    @Test func theListIsFullBleedUnderBareChrome() {
        let shop = makeShop()
        shop.view.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
        shop.view.layoutIfNeeded()
        #expect(shop.collectionView.superview === shop.view)
        #expect(shop.collectionView.frame == shop.view.bounds)
        #expect(shop.collectionView.topEdgeEffect.isHidden)
        #expect(shop.navigationItem.searchController != nil)
        #expect(shop.navigationItem.preferredSearchBarPlacement == .stacked)
    }

    /// The Explore header's door: an existing, unrestricted symbol.
    @Test func theShopDoorIsAStorefront() {
        #expect(CountryShopEntry.symbolName == "storefront")
        #expect(UIImage(systemName: CountryShopEntry.symbolName) != nil)
    }
}
