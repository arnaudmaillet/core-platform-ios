import UIKit

/// The glyph for GEMS — the charter's currency B, earned-only: what a stake
/// that turned out to carry information pays, after its deferred settlement
/// (`dev/economy/`). `PointsSymbol`'s counterpart, so the two currencies are
/// told apart at a glance: a red heart you commit, a cool diamond you earn.
public enum GemSymbol {
    public static let glyph = "diamond.fill"
    public static let tint: UIColor = .systemCyan
    /// The display name.
    public static let name = "Gems"

    /// A gem glyph that carries its own tint whatever the control's.
    public static func glyphImage(_ configuration: UIImage.SymbolConfiguration? = nil) -> UIImage? {
        let image = configuration.map { UIImage(systemName: glyph, withConfiguration: $0) }
            ?? UIImage(systemName: glyph)
        return image?.withTintColor(tint, renderingMode: .alwaysOriginal)
    }
}
