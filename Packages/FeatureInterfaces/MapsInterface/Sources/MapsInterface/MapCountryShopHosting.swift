import UIKit

/// A map screen that sells countries and can open its shop — so the Explore
/// header, which the shell owns, can wear the shop's door beside the points
/// badge: `[bell] ——— [shop][points][search]`.
///
/// Adopted by the view controller `MapsFeatureBuilding.makeMapViewController()`
/// returns; the shell casts to it rather than growing the builder, because the
/// shop is the SCREEN's (it frames the map, lifts the country) and not the
/// feature's.
@MainActor
public protocol MapCountryShopHosting: AnyObject {
    /// Whether countries are sold at all — no shop door when they are not
    /// (the fleet, until the backend carries unlocks).
    var sellsCountries: Bool { get }
    /// Opens the countries shop over the map.
    func presentCountryShop()
}

/// The shop's name and its door's glyph, in one place: the Explore header's
/// bar item and the shop's own title read them, so the door and the screen
/// it opens cannot drift apart.
public enum CountryShopEntry {
    /// The shop's title, and the door's accessibility label.
    public static let title = "Shop"
    /// SF Symbols 5 (iOS 17+), unrestricted — an outline like the header's
    /// bell and magnifying glass beside it.
    public static let symbolName = "storefront"
}
