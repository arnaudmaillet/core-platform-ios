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
        let homeCountry: String? = "FR"
        var gems = 40
        var purchasesRestricted = false
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
        #expect(header(shop, .unlocked) == "Unlocked 3")
        #expect(header(shop, .locked) == "Locked 4")
        #expect(shop.headerContent(for: .progress) == nil)
        // The count is the section title's secondary number, spoken whole.
        #expect(shop.headerContent(for: .locked)?.countAccessibilityValue == "4 countries")
    }

    /// A header as the eye reads it: the title, then its secondary count.
    private func header(_ shop: CountryShopViewController, _ section: CountryShopViewController.Section) -> String? {
        shop.headerContent(for: section).map { [$0.title, $0.count].compactMap { $0 }.joined(separator: " ") }
    }

    /// "an" is in France (unlocked) and Germany (locked): one search, both
    /// sections, each header counting its results.
    @Test func searchSpansBothSections() {
        let shop = makeShop()
        #expect(CountryAtlas.shared.country(code: "DE")?.name == "Germany")
        search(shop, "an")
        #expect(codes(shop, in: .unlocked) == ["FR"])
        #expect(codes(shop, in: .locked) == ["DE"])
        #expect(header(shop, .unlocked) == "Unlocked 1")
        #expect(header(shop, .locked) == "Locked 1")
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
        #expect(header(shop, .locked) == "Locked 3")
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

    /// The list is the whole sheet, and the rows passing under the bar soften
    /// into the system's SOFT top edge effect — the progressive blur, not the
    /// automatic frost a titled bar would pick.
    @Test func theListIsFullBleedUnderTheSoftEdge() {
        let shop = makeShop()
        shop.view.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
        shop.view.layoutIfNeeded()
        #expect(shop.collectionView.superview === shop.view)
        #expect(shop.collectionView.frame == shop.view.bounds)
        #expect(!shop.collectionView.topEdgeEffect.isHidden)
        #expect(shop.collectionView.topEdgeEffect.style == .soft)
        #expect(shop.contentScrollView(for: .top) === shop.collectionView)
        #expect(shop.navigationItem.searchController != nil)
        #expect(shop.navigationItem.preferredSearchBarPlacement == .stacked)
    }

    /// A PLAIN list: every row spans the sheet's full width (no inset-grouped
    /// card around a section), its content on the standard margins, and the
    /// headers scroll with their rows.
    @Test func rowsSpanTheFullWidthOfAPlainList() throws {
        #expect(CountryShopViewController.listAppearance == .plain)
        let shop = makeShop()
        shop.view.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
        shop.view.layoutIfNeeded()
        let list = shop.collectionView
        for code in ["FR", "US", "CN"] {
            let path = try #require(shop.dataSource.indexPath(for: .country(code)))
            let row = try #require(list.cellForItem(at: path) as? CountryShopRowCell)
            #expect(row.frame.minX == 0, "\(code) starts inside a card")
            #expect(row.frame.width == 402, "\(code) is narrower than the sheet")
            // The text sits on the cell's own layout margins — the classic
            // list inset, not flush with the edge.
            let name = row.nameLabel.convert(row.nameLabel.bounds, to: list)
            #expect(name.minX >= row.contentView.directionalLayoutMargins.leading)
            #expect(name.minX > 16, "the name is not inset past the flag")
            // No resting ground: the sheet's glass runs behind the row.
            #expect(row.backgroundConfiguration?.backgroundColor == .clear)
        }
        let header = try #require(list.collectionViewLayout
            .layoutAttributesForSupplementaryView(
                ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: 1)
            ))
        #expect(header.frame.minX == 0 && header.frame.width == 402)

        // Scrolled well past the Unlocked section, its header has gone with
        // its rows rather than pinning under the bar.
        list.contentOffset.y = 400
        list.layoutIfNeeded()
        let scrolled = list.collectionViewLayout.layoutAttributesForSupplementaryView(
            ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: 1)
        )
        #expect((scrolled?.frame.minY ?? 0) < 400, "the Unlocked header pinned to the top")
    }

    /// A row's heart is an image view in its own red: the medium sheet is
    /// glass, and glass greys a label's attachments.
    @Test func aRowDrawsItsHeartAsAnImageView() throws {
        let shop = makeShop()
        shop.view.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
        shop.view.layoutIfNeeded()
        let path = try #require(shop.dataSource.indexPath(for: .country("FR")))
        let row = try #require(shop.collectionView.cellForItem(at: path) as? CountryShopRowCell)
        #expect(row.nameLabel.text == "France")
        #expect(row.heartView.image?.renderingMode == .alwaysOriginal)
        #expect(row.nameLabel.attributedText?.containsAttachments(in: NSRange(location: 0, length: 6)) == false)
    }

    // MARK: - Boosts

    /// A ×100 pack seller over a plain count, mirroring the wallet's rules
    /// and its numbers (`WalletStore.Policy.StakePack`: 3 shots, 50 gems).
    private final class FakePacks: StakePackSelling {
        let access: FakeAccess
        var shotsLeft = 0
        init(access: FakeAccess) { self.access = access }

        var offer: StakePackOffer {
            StakePackOffer(shotsPerPack: 3, pointsPerShot: 100, price: 50, shotsLeft: shotsLeft)
        }

        func buyPack() -> StakePackPurchase {
            guard shotsLeft == 0 else { return .packStillActive(shotsLeft: shotsLeft) }
            guard access.gems >= 50 else { return .insufficientGems(needed: 50, have: access.gems) }
            access.gems -= 50
            shotsLeft = 3
            NotificationCenter.default.post(name: .stakePackDidChange, object: self)
            return .bought(shots: 3, remainingGems: access.gems)
        }
    }

    private func packRow(_ shop: CountryShopViewController) throws -> StakePackRowCell {
        shop.view.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
        shop.view.layoutIfNeeded()
        let path = try #require(shop.dataSource.indexPath(for: .stakePack))
        return try #require(shop.collectionView.cellForItem(at: path) as? StakePackRowCell)
    }

    /// With a seller, Boosts leads the list — one row the collapsed sheet
    /// always shows — and the map's sections follow as before.
    @Test func boostsLeadTheListWithTheCartridgePack() throws {
        let access = FakeAccess()
        let shop = CountryShopViewController(access: access, stakePacks: FakePacks(access: access))
        shop.loadViewIfNeeded()
        let snapshot = shop.dataSource.snapshot()
        #expect(snapshot.sectionIdentifiers == [.boosts, .progress, .unlocked, .locked])
        #expect(snapshot.itemIdentifiers(inSection: .boosts) == [.stakePack])
        #expect(header(shop, .boosts) == "Boosts")

        let row = try packRow(shop)
        #expect(row.titleLabel.text == "×100 cartridges")
        #expect(row.detailLabel.text == "3 shots · 100 points a tap")
        #expect(row.accessibilityValue == "50 gems")
    }

    /// Opened by the stake menu's "Get ×100 cartridges in the Shop": the
    /// same sheet, focused on Boosts, whose pack row flashes (selected, then
    /// let go) — and opened to browse, it carries no focus.
    @Test func theStakeMenusShopFlashesTheCartridgePack() throws {
        let access = FakeAccess()
        let packs = FakePacks(access: access)
        let sheet = CountryShopViewController.sheet(access: access, stakePacks: packs, focus: .boosts)
        let shop = try #require((sheet as? UINavigationController)?.viewControllers.first as? CountryShopViewController)
        #expect(shop.focus == .boosts)
        #expect(sheet.sheetPresentationController?.selectedDetentIdentifier == .medium)
        let browsing = CountryShopViewController.sheet(access: access, stakePacks: packs)
        #expect(((browsing as? UINavigationController)?.viewControllers.first as? CountryShopViewController)?.focus == nil)

        let row = try packRow(shop)
        let path = try #require(shop.dataSource.indexPath(for: .stakePack))
        shop.flashStakePack()
        #expect(shop.collectionView.indexPathsForSelectedItems == [path])
        #expect(row.isSelected)
    }

    /// A refused pack says why (#803) — it used to be a vibration with no
    /// words — in a failure toast over the shop.
    @Test func aRefusedPackSaysWhy() throws {
        let access = FakeAccess()
        access.gems = 70
        let packs = FakePacks(access: access)
        let shop = CountryShopViewController(access: access, stakePacks: packs)
        shop.loadViewIfNeeded()
        shop.buyStakePack()
        #expect(Self.toast(in: shop.view) == nil, "a bought pack raised a toast over its own row")

        #expect(shop.buyStakePack() == .packStillActive(shotsLeft: 3))
        let toast = try #require(Self.toast(in: shop.view), "the refusal was a vibration with no words")
        #expect(toast.style == .failure)

        #expect(CountryShopViewController.refusalMessage(for: .packStillActive(shotsLeft: 3))
                == "Your pack is still active, 3 left")
        #expect(CountryShopViewController.refusalMessage(for: .insufficientGems(needed: 50, have: 20))
                == "30 more gems needed")
        #expect(CountryShopViewController.refusalMessage(for: .bought(shots: 3, remainingGems: 20)) == nil)
    }

    private static func toast(in view: UIView) -> ToastView? {
        if let toast = view as? ToastView { return toast }
        return view.subviews.lazy.compactMap { toast(in: $0) }.first
    }

    /// Without one — the fleet — there is no Boosts section at all.
    @Test func noSellerNoBoosts() {
        let shop = makeShop()
        #expect(shop.dataSource.snapshot().sectionIdentifiers.contains(.boosts) == false)
    }

    /// Teen protections (#401): an account aged 13–17 buys nothing, and its
    /// gems stay where they are.
    @Test func aTeenAccountCannotBuyThePack() {
        let access = FakeAccess()
        access.gems = 70
        access.purchasesRestricted = true
        let packs = FakePacks(access: access)
        let shop = CountryShopViewController(access: access, stakePacks: packs)
        shop.loadViewIfNeeded()

        #expect(shop.buyStakePack() == nil)
        #expect(access.gems == 70)
        #expect(PurchaseRestriction.message.contains("under 18"))
    }

    /// Buying spends the gems and turns the price into "Active — 10 left";
    /// while it lasts, a second pack is refused (packs don't stack).
    @Test func buyingThePackShowsItActiveAndRefusesAnother() throws {
        let access = FakeAccess()
        access.gems = 70
        let packs = FakePacks(access: access)
        let shop = CountryShopViewController(access: access, stakePacks: packs)
        shop.loadViewIfNeeded()

        #expect(shop.buyStakePack() == .bought(shots: 3, remainingGems: 20))
        #expect(access.gems == 20)
        let row = try packRow(shop)
        #expect(row.accessibilityValue == "Active — 3 left")
        #expect(CountryShopViewController.activeText(packs.offer) == "Active — 3 left")

        #expect(shop.buyStakePack() == .packStillActive(shotsLeft: 3))
        #expect(access.gems == 20)

        // Spent down (in the feed), the price comes back.
        packs.shotsLeft = 0
        NotificationCenter.default.post(name: .stakePackDidChange, object: packs)
        #expect(try packRow(shop).accessibilityValue == "50 gems")
    }

    /// Boosts is not a country: a search hides it, clearing it brings it back.
    @Test func aSearchHidesBoosts() {
        let access = FakeAccess()
        let shop = CountryShopViewController(access: access, stakePacks: FakePacks(access: access))
        shop.loadViewIfNeeded()
        search(shop, "an")
        #expect(shop.dataSource.snapshot().sectionIdentifiers.first == .progress)
        search(shop, "")
        #expect(shop.dataSource.snapshot().sectionIdentifiers.first == .boosts)
    }

    /// The Explore header's door: an existing, unrestricted symbol.
    @Test func theShopDoorIsAStorefront() {
        #expect(CountryShopEntry.symbolName == "storefront")
        #expect(UIImage(systemName: CountryShopEntry.symbolName) != nil)
    }
}
