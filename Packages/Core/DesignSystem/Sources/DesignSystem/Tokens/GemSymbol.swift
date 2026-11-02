import UIKit

/// The glyph for GEMS — the charter's currency B, earned-only: what a stake
/// that turned out to carry information pays, after its deferred settlement
/// (`dev/economy/`). `LikesSymbol`'s counterpart, so the two currencies are
/// told apart at a glance: a red heart you commit, a violet diamond you earn.
public enum GemSymbol {
    public static let glyph = AppSymbol.gemFilled.rawValue
    /// The palette's violet (#2062), the gems' alone: a GLYPH colour (3:1).
    /// It was the system cyan once (#1124), which said nothing.
    public static let tint: UIColor = Palette.gemViolet
    /// The same violet as TEXT — "+N", a price, a balance: a deeper step in
    /// the light, where the glyph's violet is under 4.5:1.
    public static let textColor: UIColor = Palette.gemText
    /// The display name.
    public static let name = "Gems"

    /// A gem glyph that carries its own tint whatever the control's.
    public static func glyphImage(_ configuration: UIImage.SymbolConfiguration? = nil) -> UIImage? {
        let image = UIImage.symbol(named: glyph, configuration: configuration)
        return image?.withTintColor(tint, renderingMode: .alwaysOriginal)
    }
}
