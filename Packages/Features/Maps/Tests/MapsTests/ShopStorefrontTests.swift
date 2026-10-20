import DesignSystem
import MapsInterface
import Testing
import UIKit
@testable import Maps

/// The Shop's storefront (#1075): shelves of categories — Boosts as portrait
/// cards, Countries as a horizontal list — each heading pushing the whole
/// category, and nothing bought without a confirmation.
@MainActor
struct ShopStorefrontTests {
    private final class FakeAccess: CountryAccess {
        let homeCountry: String? = "FR"
        var currentCountry: String? = nil
        var gems = 40
        var purchasesRestricted = false
        var unlocked: Set<String> = ["FR", "US"]
        let all: [CountryStanding] = [
            "US", "CN", "IN", "ES", "FR", "DE", "IT", "JP", "BR", "MX", "NG", "EG", "KE", "PE",
        ].enumerated().map { index, code in
            CountryStanding(
                code: code, rank: index + 1, likes: 1_000, posts: 10,
                price: code == "FR" ? 0 : CountryStanding.price(forRank: index + 1)
            )
        }
        private(set) var unlocks: [String] = []

        func isUnlocked(_ code: String) -> Bool { unlocked.contains(code) }
        func standing(of code: String) -> CountryStanding? { all.first { $0.code == code } }
        func standings() -> [CountryStanding] { all.reversed() }
        func unlock(_ code: String) -> CountryUnlockOutcome {
            unlocks.append(code)
            unlocked.insert(code)
            return .unlocked(remainingGems: gems)
        }
    }

    /// Three packs (backend #941): 3, 10 and 25 shots.
    private final class FakePacks: StakePackSelling {
        let access: FakeAccess
        var loaded: (id: String, shotsLeft: Int)?
        private(set) var bought: [String] = []
        init(access: FakeAccess) { self.access = access }
        static let tiers: [(id: String, shots: Int, price: Int)] = [("shots_3", 3, 50), ("shots_10", 10, 150), ("shots_25", 25, 325)]
        var offers: [StakePackOffer] {
            Self.tiers.map { tier in
                StakePackOffer(
                    id: tier.id, shotsPerPack: tier.shots, likesPerShot: 100, price: tier.price,
                    shotsLeft: loaded?.id == tier.id ? loaded?.shotsLeft ?? 0 : 0
                )
            }
        }
        var offer: StakePackOffer { offers.first(where: \.isActive) ?? offers[0] }
        func buyPack() async -> StakePackPurchase { await buyPack(offers[0]) }
        func buyPack(_ offer: StakePackOffer) async -> StakePackPurchase {
            if let loaded { return .packStillActive(shotsLeft: loaded.shotsLeft) }
            guard access.gems >= offer.price else { return .insufficientGems(needed: offer.price, have: access.gems) }
            bought.append(offer.id)
            access.gems -= offer.price
            loaded = (offer.id, offer.shotsPerPack)
            return .bought(shots: offer.shotsPerPack, remainingGems: access.gems)
        }
    }

    private func front(_ access: FakeAccess = FakeAccess(), packs: Bool = true) -> (ShopStorefrontViewController, UINavigationController) {
        let front = ShopStorefrontViewController(access: access, stakePacks: packs ? FakePacks(access: access) : nil)
        let navigation = UINavigationController(rootViewController: front)
        navigation.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        navigation.view.layoutIfNeeded()
        front.view.layoutIfNeeded()
        return (front, navigation)
    }

    private func countryRows(_ front: ShopStorefrontViewController) -> [ShopCountryCardView] {
        front.countryCards
    }

    // MARK: - Shelves

    @Test func boostsThenCountriesEachUnderItsHeading() throws {
        let (front, _) = front()
        let boosts = try #require(front.boostsShelf)
        let countries = try #require(front.countriesShelf)
        #expect(boosts.heading.debugTitleText == "Boosts")
        #expect(!boosts.heading.debugShowsChevron, "one pack: nothing more to see")
        #expect(countries.heading.debugTitleText == "Countries")
        #expect(countries.heading.debugShowsChevron, "the heading is a link to the whole list")
        #expect(countries.heading.debugCountText == "14")
        #expect(boosts.frame.maxY <= countries.frame.minY, "Boosts leads")
    }

    /// One card per pack, side by side when they are three (a price ladder
    /// is compared), each led by its SHOTS (owner, 2026-10-13).
    @Test func everyPackHasACardLedByItsShots() throws {
        let (front, _) = front()
        front.view.layoutIfNeeded()
        let cards = front.packCards
        #expect(cards.map { $0.quantityLabel.text } == ["×3", "×10", "×25"])
        let last = try #require(cards.last)
        let frame = last.convert(last.bounds, to: front.view)
        #expect(frame.maxX <= front.view.bounds.width, "the third pack is cropped: \(frame)")
        #expect(Set(cards.map { $0.bounds.height }).count == 1, "the cards are not one height")
    }

    /// "Best value" is the cheapest shot, and said of one pack only.
    @Test func bestValueIsTheCheapestShot() throws {
        let packs = FakePacks(access: FakeAccess())
        #expect(ShopPackCardView.bestValueID(in: packs.offers) == "shots_25")
        #expect(ShopPackCardView.bestValueID(in: [packs.offers[0]]) == nil, "one pack is no comparison")
        let (front, _) = front()
        #expect(front.packCards.filter { $0.badgeLabel.text == "BEST VALUE" }.map(\.offer.id) == ["shots_25"])
    }

    /// Packs don't stack: the loaded one says how many shots are left, and
    /// buying any other is refused — said in its menu.
    @Test func aLoadedPackIsMarkedAndBlocksTheOthers() throws {
        let access = FakeAccess()
        access.gems = 1_000
        let packs = FakePacks(access: access)
        packs.loaded = ("shots_10", 4)
        let front = ShopStorefrontViewController(access: access, stakePacks: packs)
        front.loadViewIfNeeded()
        let loaded = try #require(front.packCards.first { $0.offer.id == "shots_10" })
        #expect(loaded.badgeLabel.text == "LOADED")
        #expect((loaded.footLabel as? UILabel)?.text == "Active — 4 left")
        let other = try #require(packs.offers.first { $0.id == "shots_25" })
        let menu = front.packMenu(other, blockedBy: packs.offer)
        let buy = try #require(menu.children.first as? UIAction)
        #expect(buy.attributes.contains(.disabled))
        #expect(buy.subtitle?.contains("don't stack") == true)
    }

    /// Buying goes through the pack the menu belongs to.
    @Test func buyingABiggerPackLoadsItsShots() async throws {
        let access = FakeAccess()
        access.gems = 400
        let packs = FakePacks(access: access)
        let front = ShopStorefrontViewController(access: access, stakePacks: packs)
        front.loadViewIfNeeded()
        let tier = try #require(packs.offers.first { $0.id == "shots_25" })
        #expect(await front.buyStakePack(tier) == .bought(shots: 25, remainingGems: 75))
        #expect(packs.bought == ["shots_25"])
    }

    /// The countries are cards in a row (owner, 2026-10-13), a touch larger
    /// than For You's Following cards — locked countries only, the one the
    /// device is in first, then by rank, at most ten, then "See all".
    @Test func countriesAreCardsOfLockedCountries() throws {
        let access = FakeAccess()
        access.currentCountry = "PE"
        let (front, _) = front(access)
        let shelf = try #require(front.countriesShelf)
        let names = countryRows(front).map { $0.nameLabel.text ?? "" }
        #expect(names.count == 10)
        #expect(names.first == access.all.first { $0.code == "PE" }.flatMap { CountryAtlas.shared.country(code: $0.code)?.name })
        #expect(!names.contains("France") && !names.contains("United States"), "an unlocked country is on the shelf")
        #expect(shelf.items.last is ShopSeeAllRowView, "the row does not end on See all")
        front.view.layoutIfNeeded()
        let card = try #require(front.countryCards.first)
        let forYouCard = RowEdgeSnap.itemWidth(forWidth: front.view.bounds.width, perWidth: 2.3, margin: 16, gap: 16)
        #expect(card.bounds.width >= forYouCard, "smaller than For You's cards")
        #expect(card.bounds.width < front.view.bounds.width / 2, "not two to a screen")
        #expect(abs(card.bounds.height - card.bounds.width * 4 / 3) < 1, "not 3:4")
    }

    /// A card's ground: the top post — a picture, a video, or a text post's
    /// words over the flag's colours; the flag's colours alone with no post.
    @Test func aCardWearsItsCountrysCover() {
        let image = ShopCountryCardView(
            flag: UIImage(), name: "A", rank: 1, likes: "1", price: 10, inReach: true,
            cover: .image(postID: "p1", poster: URL(string: "mock://media/1")!), backdropFlag: UIImage()
        )
        #expect(image.previewURL == nil && image.quoteLabel == nil && image.postID == "p1")
        let video = ShopCountryCardView(
            flag: UIImage(), name: "B", rank: 2, likes: "1", price: 10, inReach: true,
            cover: .video(postID: "p2", poster: nil, preview: URL(string: "mock://video/2")!), backdropFlag: UIImage()
        )
        #expect(video.previewURL?.absoluteString == "mock://video/2")
        let text = ShopCountryCardView(
            flag: UIImage(), name: "C", rank: 3, likes: "1", price: 10, inReach: false,
            cover: .text(postID: "p3", caption: "Hello"), backdropFlag: UIImage()
        )
        #expect(text.quoteLabel?.text == "“Hello”")
        #expect(text.previewURL == nil)
        let none = ShopCountryCardView(
            flag: UIImage(), name: "D", rank: 4, likes: "1", price: 10, inReach: true, cover: nil, backdropFlag: UIImage()
        )
        #expect(none.postID == nil && none.quoteLabel == nil)
        #expect(!text.price.inReach)
    }

    /// The map's round flag beside the name; a country with no post shows
    /// it large, centred above the info (owner, 2026-10-13).
    @Test func aCardWithNoPostShowsItsFlagCentred() throws {
        let round = try #require(FlagPalette.roundFlag(for: "FR"))
        let large = FlagPalette.largeRoundFlag(for: "FR") ?? round
        let backdrop = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 40)).image { ctx in
            for (i, color) in [UIColor.blue, .white, .red].enumerated() {
                color.setFill()
                ctx.fill(CGRect(x: i * 20, y: 0, width: 20, height: 40))
            }
        }
        let none = ShopCountryCardView(
            flag: round, name: "France", largeFlag: large, rank: 4, likes: "1", price: 10, inReach: true,
            cover: nil, backdropFlag: backdrop
        )
        let picture = ShopCountryCardView(
            flag: round, name: "France", largeFlag: large, rank: 4, likes: "1", price: 10, inReach: true,
            cover: .image(postID: "p1", poster: URL(string: "mock://media/1")!), backdropFlag: UIImage()
        )
        #expect(picture.heroFlagView == nil, "a post's card shows the post, not the flag")
        none.frame = CGRect(x: 0, y: 0, width: 170, height: 227)
        none.layoutIfNeeded()
        let hero = try #require(none.heroFlagView)
        #expect(hero.image === large)
        #expect(abs(hero.frame.midX - none.bounds.midX) < 0.5, "not centred")
        #expect(hero.frame.width > 40 && abs(hero.frame.width - hero.frame.height) < 0.5)
        #expect(hero.frame.maxY < none.nameLabel.convert(none.nameLabel.bounds, to: none).minY, "over the info")
        #expect(hero.frame.minY > 0)
        // Its ground is still the flag's colours, blurred (owner, 2026-10-13).
        let ground = try #require(none.subviews.first)
        #expect(!ground.isHidden && ground.subviews.contains { ($0 as? UIImageView)?.image != nil })
    }

    @Test func noSellerNoBoostsShelf() {
        let (front, _) = front(packs: false)
        #expect(front.boostsShelf == nil)
        #expect(front.countriesShelf != nil)
    }

    /// Wide items page flush left, one per gesture; the countries' cards are
    /// small enough to take For You's rule.
    @Test func wideItemsPageFlushLeft() {
        let items: [ClosedRange<CGFloat>] = [16...316, 332...632, 648...948]
        let offsets: ClosedRange<CGFloat> = 0...600
        #expect(ShopShelfView.pagedTarget(start: 0, live: 250, direction: .forward, items: items, margin: 16, offsets: offsets) == 316)
        #expect(ShopShelfView.pagedTarget(start: 316, live: 100, direction: .backward, items: items, margin: 16, offsets: offsets) == 0)
        #expect(ShopShelfView.pagedTarget(start: 0, live: 290, direction: nil, items: items, margin: 16, offsets: offsets) == 316)
    }

    @Test func accessibilitySizesStackTheListVertically() {
        let access = FakeAccess()
        let front = ShopStorefrontViewController(access: access, stakePacks: nil)
        front.traitOverrides.preferredContentSizeCategory = .accessibilityExtraLarge
        front.loadViewIfNeeded()
        front.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        front.rebuild()
        #expect(front.countriesShelf?.debugIsVertical == true)
    }

    // MARK: - Prices and gems

    /// Out of reach, a price is disabled, and the shelf says how gems are
    /// EARNED — never where to buy them.
    @Test func anUnaffordablePriceIsDisabledAndTheShelfSaysHowGemsAreEarned() throws {
        let access = FakeAccess()
        access.gems = 0
        let (front, _) = front(access)
        let rows = countryRows(front)
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { !$0.price.inReach }, "an unaffordable price is drawn in reach")
        let note = try #require(front.countriesShelf?.footnoteText)
        #expect(note.contains("earned"))
        #expect(!note.lowercased().contains("buy"))
        let packPrice = try #require(front.packCards.first?.footLabel as? ShopPriceLabel)
        #expect(!packPrice.inReach)
    }

    // MARK: - Pages, never purchases

    /// The card is the button (owner, 2026-10-13): a pack's raises its
    /// confirmation menu, a country's opens its unlock sheet. Neither
    /// debits anything.
    @Test func tappingACardNeverBuys() throws {
        let access = FakeAccess()
        access.gems = 1_000
        let packs = FakePacks(access: access)
        let front = ShopStorefrontViewController(access: access, stakePacks: packs)
        let navigation = UINavigationController(rootViewController: front)
        navigation.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        navigation.view.layoutIfNeeded()

        let card = try #require(front.packCard)
        #expect(card.hitArea.showsMenuAsPrimaryAction, "a pack's card buys without its confirmation")
        #expect(card.hitArea.menu != nil)
        let row = try #require(countryRows(front).first)
        #expect(!row.hitArea.showsMenuAsPrimaryAction)
        row.hitArea.sendActions(for: .primaryActionTriggered)
        #expect(access.gems == 1_000, "opening an item spent gems")
        #expect(packs.bought.isEmpty)
        #expect(access.unlocks.isEmpty)
    }

    /// The heading — and the list's last row — push the whole country list.
    @Test func seeAllPushesTheCountryList() throws {
        let (front, navigation) = front()
        let openList: (() -> Void)? = front.countriesShelf?.heading.onTap
        let open = try #require(openList)
        open()
        let list = try #require(navigation.viewControllers.last as? CountryShopViewController)
        #expect(list.title == "Countries")
        navigation.popViewController(animated: false)
        let seeAll = try #require(front.countriesShelf?.items.last as? ShopSeeAllRowView)
        seeAll.onOpen?()
        #expect(navigation.viewControllers.last is CountryShopViewController)
    }


    /// A pushed screen: the back button leads, the gems stand on the right,
    /// no tab bar (owner, 2026-10-13).
    @Test func theBarIsBackTitleGems() throws {
        let (front, _) = front()
        #expect(front.hidesBottomBarWhenPushed)
        let gems = try #require(front.navigationItem.rightBarButtonItem)
        #expect(gems.identifier == CountryShopViewController.balanceItemIdentifier)
        #expect(front.navigationItem.rightBarButtonItems?.count == 1)
        #expect(front.navigationItem.leftBarButtonItems?.isEmpty ?? true)
    }

    /// A row keeps a horizontal drag while it has somewhere to go, and hands
    /// it on at its ends: at its start a rightward drag is the screen's back
    /// swipe; from the leading edge strip, always.
    @Test func aRowHandsItsDragOnAtItsEnds() {
        let row = ShopShelfRowScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        row.contentSize = CGSize(width: 1_200, height: 200)
        let right = CGPoint(x: 500, y: 20)
        let left = CGPoint(x: -500, y: 20)

        row.contentOffset.x = 0
        #expect(!row.keepsDrag(fromScreenX: 200, velocity: right), "at its start: the back swipe's")
        #expect(row.keepsDrag(fromScreenX: 200, velocity: left))

        row.contentOffset.x = 400
        #expect(row.keepsDrag(fromScreenX: 200, velocity: right))
        #expect(row.keepsDrag(fromScreenX: 200, velocity: left))
        #expect(!row.keepsDrag(fromScreenX: 10, velocity: left), "the edge strip is the back swipe's")

        row.contentOffset.x = 800
        #expect(!row.keepsDrag(fromScreenX: 200, velocity: left), "at its end: nothing left to show")
        #expect(row.keepsDrag(fromScreenX: 200, velocity: right))
        // A vertical drag is the page's, never refused here.
        row.contentOffset.x = 0
        #expect(row.keepsDrag(fromScreenX: 200, velocity: CGPoint(x: 10, y: 600)))
    }


    /// A shelf's title stands the surface's 20pt in wherever the page sits:
    /// SAID, not measured (owner, 2026-10-13: "Boosts" drawn ~200pt in after
    /// opening — measured, it read the page's position mid-push and kept it).
    @Test func aHeadingsInsetIsSaidNotMeasured() throws {
        let (front, _) = front()
        let page = try #require(front.view.subviews.first as? UIScrollView)
        // A push's sliding safe area never insets the page sideways, nor a row.
        #expect(page.contentInsetAdjustmentBehavior == .scrollableAxes)
        #expect(front.countriesShelf?.row.contentInsetAdjustmentBehavior == .never)
        let heading = try #require(front.boostsShelf?.heading)
        #expect(heading.fixedInset == SectionTitleView.Metrics.surfaceInset)
        let label = try #require(heading.subviews.compactMap { $0 as? UILabel }.first { $0.text == "Boosts" })
        // Laid out while the page sits 200pt off its rest: still 20pt in.
        page.contentOffset.x = 200
        heading.setNeedsLayout()
        heading.layoutIfNeeded()
        #expect(abs(label.frame.minX - SectionTitleView.Metrics.surfaceInset) < 0.5)
    }

}
