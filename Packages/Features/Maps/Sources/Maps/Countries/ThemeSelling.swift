import CoreStorage
import DesignSystem
import Foundation

/// An accent theme on the Shop's shelf (#1379): which one, and its price in
/// gems — 0 for the free pink, which every account owns.
public struct ThemeOffer: Equatable, Sendable {
    public let theme: AccentTheme
    public let price: Int

    public init(theme: AccentTheme, price: Int) {
        self.theme = theme
        self.price = price
    }
}

/// The accent themes the Shop sells and the viewer applies (#1379).
///
/// Answered by the shell over the wallet and the account's items, as
/// `ProfileItemSelling` is; the Shop never touches either. A theme is
/// bought once, for good, by the ACCOUNT; applying it is a device setting
/// (`AccentThemePreference`).
@MainActor
public protocol ThemeSelling: AnyObject {
    /// The shelf, in order: pink first.
    var offers: [ThemeOffer] { get }
    func owns(_ theme: AccentTheme) -> Bool
    /// The theme the app draws in now.
    var applied: AccentTheme { get }
    func buy(_ theme: AccentTheme) -> ProfileItemPurchase
    /// Draws the app in `theme`, at once — an owned one only.
    func apply(_ theme: AccentTheme)
}

extension AccentTheme {
    /// What the Shop says it changes.
    var shopDetail: String {
        switch self {
        case .pink: "The app's own pink"
        case .violet: "Violet accents, pink highlights"
        case .red: "Red accents across the app"
        }
    }
}
