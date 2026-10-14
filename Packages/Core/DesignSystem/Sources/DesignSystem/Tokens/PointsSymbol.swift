import UIKit

/// The glyph for POINTS — what the wallet holds and what a boost spends.
///
/// ⚠️ **A HEART, because points ARE likes** (product decision, 25 September
/// 2026: "boost, j'aime, points sont la même chose"). They were a star, and
/// the star was spelled out at every surface that drew one — the wallet badge,
/// the claim screen, the comment bar's boost and the rail's — so this is the
/// one name they all read. NOT the Save star (#1128), which is not a point.
public enum PointsSymbol {
    /// The glyph on a boost control and beside an amount.
    public static let glyph = AppSymbol.liked.rawValue
    /// The coin: the wallet's balance badge and the claim screen.
    public static let coin = "heart.circle.fill"
    /// Points' colour: the pink (#1178, the owner 2026-10-15). It was a
    /// like's red (25 September 2026).
    public static var tint: UIColor { Palette.tint }
    /// The heart's fill for an appearance — the pink, solid (#1178; it was
    /// #1124's yellow → orange → pink, then a solid red).
    public static func gradient(for traits: UITraitCollection) -> [UIColor] {
        Palette.pointsGradient(for: traits)
    }
    /// The coin as drawn: a white heart on a pink disc — a token that reads at
    /// badge size, where a pink heart alone on the bar's glass would not.
    public static var coinPalette: UIImage.SymbolConfiguration {
        UIImage.SymbolConfiguration(paletteColors: [.white, tint])
    }
    /// A points glyph that carries its own pink whatever the control's tint.
    public static func glyphImage(_ configuration: UIImage.SymbolConfiguration? = nil) -> UIImage? {
        let image = UIImage.symbol(named: glyph, configuration: configuration)
        return image?.withTintColor(tint, renderingMode: .alwaysOriginal)
    }

    /// The like heart of the snap feed's stake controls.
    ///
    /// - At rest (#680): the OUTLINE heart as a TEMPLATE — the control's own
    ///   foreground draws it, in the content's text ink (white over media, the
    ///   page's ink on a light panel).
    /// - Staked: the points' pink FILL, carrying its own colour.
    ///
    /// A heart either way, never a number (#668).
    public static func likeImage(staked: Bool, _ configuration: UIImage.SymbolConfiguration? = nil) -> UIImage? {
        let name = staked ? glyph : outlineGlyph
        let image = UIImage.symbol(named: name, configuration: configuration)
        return staked
            ? image?.withTintColor(tint, renderingMode: .alwaysOriginal)
            : image?.withRenderingMode(.alwaysTemplate)
    }

    /// The like heart at rest: an outline.
    public static let outlineGlyph = AppSymbol.like.rawValue
}
