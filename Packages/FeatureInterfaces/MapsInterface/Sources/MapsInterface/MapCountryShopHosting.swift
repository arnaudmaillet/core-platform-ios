import UIKit

/// A map screen that sells countries and can open its shop — so the Explore
/// header, which the shell owns, can wear the shop's globe beside the points
/// badge: `[bell] ——— [globe][points][search]`.
///
/// Adopted by the view controller `MapsFeatureBuilding.makeMapViewController()`
/// returns; the shell casts to it rather than growing the builder, because the
/// shop is the SCREEN's (it frames the map, lifts the country) and not the
/// feature's.
@MainActor
public protocol MapCountryShopHosting: AnyObject {
    /// Whether countries are sold at all — no globe when they are not (the
    /// fleet, until the backend carries unlocks).
    var sellsCountries: Bool { get }
    /// Opens the countries shop over the map.
    func presentCountryShop()
}
