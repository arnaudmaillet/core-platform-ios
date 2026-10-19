import UIKit

/// The glyph for GEMS — the charter's currency B, earned-only: what a stake
/// that turned out to carry information pays, after its deferred settlement
/// (`dev/economy/`). `LikesSymbol`'s counterpart, so the two currencies are
/// told apart at a glance: a red heart you commit, a violet diamond you earn.
public enum GemSymbol {
    public static let glyph = AppSymbol.gemFilled.rawValue
    /// The brand's secondary, violet (#1124): it was the system cyan, which
    /// clashed with nothing but said nothing either.
    public static let tint: UIColor = Palette.secondary
    /// The display name.
    public static let name = "Gems"

    /// A gem glyph that carries its own tint whatever the control's.
    public static func glyphImage(_ configuration: UIImage.SymbolConfiguration? = nil) -> UIImage? {
        let image = UIImage.symbol(named: glyph, configuration: configuration)
        return image?.withTintColor(tint, renderingMode: .alwaysOriginal)
    }
}
