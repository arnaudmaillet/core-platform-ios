import UIKit

/// The glyph for POINTS — what the wallet holds and what a boost spends.
///
/// ⚠️ **A HEART, because points ARE likes** (product decision, 25 September
/// 2026: "boost, j'aime, points sont la même chose"). They were a star, and
/// the star was spelled out at every surface that drew one — the wallet badge,
/// the claim screen, the comment bar's boost and the rail's — so this is the
/// one name they all read. NOT the profile's favourite star (pin to map), which
/// is not a point.
public enum PointsSymbol {
    /// The glyph on a boost control and beside an amount.
    public static let glyph = "heart.fill"
    /// The coin: the wallet's balance badge and the claim screen.
    public static let coin = "heart.circle.fill"
    /// Points' colour — a like's red (product decision, 25 September 2026),
    /// where points used to be wallet gold.
    public static let tint: UIColor = .systemRed
    /// The coin as drawn: a white heart on a red disc — a token that reads at
    /// badge size, where a red heart alone on the bar's glass would not.
    public static var coinPalette: UIImage.SymbolConfiguration {
        UIImage.SymbolConfiguration(paletteColors: [.white, tint])
    }
    /// A points glyph that carries its own red whatever the control's tint.
    public static func glyphImage(_ configuration: UIImage.SymbolConfiguration? = nil) -> UIImage? {
        let image = configuration.map { UIImage(systemName: glyph, withConfiguration: $0) }
            ?? UIImage(systemName: glyph)
        return image?.withTintColor(tint, renderingMode: .alwaysOriginal)
    }
}
