import CoreStorage
import DesignSystem
import MapsInterface
import Testing
import UIKit
@testable import Maps

/// The Shop's Themes shelf (#1379): pink free and owned, violet and red at
/// their price; bought once, applied from the card; each swatch drawn in its
/// own theme whatever the app wears.
@MainActor
struct ShopThemesTests {
    private final class Access: CountryAccess {
        let homeCountry: String? = "FR"
        var currentCountry: String? = nil
        var gems = 80
        var purchasesRestricted = false
        func isUnlocked(_ code: String) -> Bool { code == "FR" }
        func standing(of code: String) -> CountryStanding? { nil }
        func standings() -> [CountryStanding] { [] }
        func unlock(_ code: String) -> CountryUnlockOutcome { .unknownCountry }
    }

    private final class Themes: ThemeSelling {
        let access: Access
        var owned: Set<AccentTheme> = [.pink]
        var applied: AccentTheme = .pink
        private(set) var appliedLog: [AccentTheme] = []
        init(access: Access) { self.access = access }
        var offers: [ThemeOffer] {
            [ThemeOffer(theme: .pink, price: 0), ThemeOffer(theme: .violet, price: 50), ThemeOffer(theme: .red, price: 50)]
        }
        func owns(_ theme: AccentTheme) -> Bool { owned.contains(theme) }
        func buy(_ theme: AccentTheme) async -> ProfileItemPurchase {
            guard !owned.contains(theme) else { return .alreadyOwned }
            guard access.gems >= 50 else { return .insufficientGems(needed: 50, have: access.gems) }
            access.gems -= 50
            owned.insert(theme)
            return .bought(remainingGems: access.gems)
        }
        func apply(_ theme: AccentTheme) {
            applied = theme
            appliedLog.append(theme)
        }
    }

    private func front(_ access: Access, themes: Themes?) -> (ShopStorefrontViewController, UINavigationController) {
        let front = ShopStorefrontViewController(access: access, stakePacks: nil, themes: themes)
        let navigation = UINavigationController(rootViewController: front)
        navigation.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        navigation.view.layoutIfNeeded()
        front.view.layoutIfNeeded()
        return (front, navigation)
    }

    private static func hex(_ colour: UIColor) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        colour.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UInt32((r * 255).rounded()) << 16 | UInt32((g * 255).rounded()) << 8 | UInt32((b * 255).rounded())
    }

    @Test func noSellerNoThemesShelf() {
        let (front, _) = front(Access(), themes: nil)
        #expect(front.themesShelf == nil)
    }

    /// Its own shelf after the countries: pink in use, the others priced.
    @Test func theThemesShelfShowsEachThemesState() throws {
        let access = Access()
        let (front, _) = front(access, themes: Themes(access: access))
        let shelf = try #require(front.themesShelf)
        #expect(shelf.heading.debugTitleText == "Themes")
        #expect(front.themeCards.map(\.offer.theme) == [.pink, .violet, .red])
        #expect(front.themeCards.map(\.accessibilityValue) == ["In use", "50 gems", "50 gems"])
        let countries = try #require(front.countriesShelf)
        #expect(countries.frame.maxY <= shelf.frame.minY)
    }

    /// Each swatch draws its own theme's gradient — accent, then secondary —
    /// in a pink app.
    @Test func eachSwatchDrawsItsOwnTheme() throws {
        let access = Access()
        let (front, navigation) = front(access, themes: Themes(access: access))
        let window = UIWindow(frame: navigation.view.frame)
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let swatches = front.themeCards.map { $0.drawnSwatch.map(Self.hex) }
        #expect(swatches == [[0xF37AB4, 0xA78BFA], [0xA78BFA, 0xF37AB4], [0xE5484D, 0xA78BFA]])
    }

    /// Bought: the gems are spent, the card turns Owned, nothing is applied
    /// until asked; a second buy spends nothing.
    @Test func buyingTurnsTheCardOwnedWithoutApplyingIt() async throws {
        let access = Access()
        let themes = Themes(access: access)
        let (front, _) = front(access, themes: themes)
        let violet = try #require(themes.offers.first { $0.theme == .violet })
        #expect(await front.buyTheme(violet) == .bought(remainingGems: 30))
        front.rebuild()
        #expect(front.themeCards.map(\.accessibilityValue) == ["In use", "Owned", "50 gems"])
        #expect(themes.appliedLog.isEmpty, "buying never applies by itself")
        #expect(await front.buyTheme(violet) == .alreadyOwned)
        #expect(access.gems == 30)
    }

    /// Owned, the card's menu applies it; in use, it is a label.
    @Test func anOwnedThemeAppliesFromItsMenu() throws {
        let access = Access()
        let themes = Themes(access: access)
        themes.owned.insert(.red)
        let (front, _) = front(access, themes: themes)
        let pink = try #require(themes.offers.first { $0.theme == .pink })
        let label = try #require(front.themeMenu(pink, owned: true, seller: themes).children.first as? UIAction)
        #expect(label.title == "In use")
        #expect(label.attributes.contains(.disabled))
        let red = try #require(themes.offers.first { $0.theme == .red })
        let apply = try #require(front.themeMenu(red, owned: true, seller: themes).children.first as? UIAction)
        #expect(apply.title == "Apply")
        #expect(!apply.attributes.contains(.disabled))
        front.applyTheme(.red)
        #expect(themes.appliedLog == [.red])
    }

    /// A theme not owned never applies, whatever asks.
    @Test func anUnownedThemeNeverApplies() {
        let access = Access()
        let themes = Themes(access: access)
        let (front, _) = front(access, themes: themes)
        front.applyTheme(.violet)
        #expect(themes.appliedLog.isEmpty)
    }

    /// Short of gems, the confirmation is disabled with how many are missing.
    @Test func shortOfGemsTheBuyIsDisabledAndSaysWhy() throws {
        let access = Access()
        access.gems = 12
        let themes = Themes(access: access)
        let (front, _) = front(access, themes: themes)
        let red = try #require(themes.offers.first { $0.theme == .red })
        let buy = try #require(front.themeMenu(red, owned: false, seller: themes).children.first as? UIAction)
        #expect(buy.attributes.contains(.disabled))
        #expect(buy.subtitle == "38 more gems needed")
    }
}
