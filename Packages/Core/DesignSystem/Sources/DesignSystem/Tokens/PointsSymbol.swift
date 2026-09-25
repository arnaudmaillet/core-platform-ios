import Foundation

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
}
