import UIKit

/// The glyph for GEMS — the charter's currency B, earned-only: what a stake
/// that turned out to carry information pays, after its deferred settlement
/// (`dev/economy/`). `LikesSymbol`'s counterpart, so the two currencies are
/// told apart at a glance: a heart in the primary you commit, a gold crown you
/// earn (the owner's crown since #2071; a violet diamond before).
public enum GemSymbol {
    /// The owner's crown, filled (#2071).
    public static let glyph = AppSymbol.crownFilled.rawValue
    /// The crown's colour (`Palette.gem`): a bright gold on light grounds,
    /// the brand's yellow on dark ones. One colour, so a reader that tints
    /// the symbol draws it right. In the light it is under a glyph's 3:1:
    /// draw the crown beside its amount, in `textColor`.
    public static let tint: UIColor = Palette.gem
    /// The same gold as TEXT — "+N", a price, a balance: a deeper step in
    /// the light, where the glyph's gold is under 4.5:1.
    public static let textColor: UIColor = Palette.gemText
    /// The wash under a price or a claim, at the reader's alpha: the yellow.
    public static let ground: UIColor = Palette.gemGround
    /// ⚠️ THE CURRENCY'S NAME, IN ONE PLACE (#2072, the owner 2026-11-02):
    /// "Crowns" wherever the user reads or hears it. The code, the contracts,
    /// persisted keys and flags still say gems (`Currency.gems`,
    /// `wallet.gemsGranted`, `-wallet-gems`): a rename there is churn with no
    /// user benefit, and the contracts are shared with the backend.
    public static let name = "Crowns"

    /// A counted amount: "1 crown", "12 crowns", "1,200 crowns" — the
    /// number grouped as the locale does.
    public static func amount(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "crown" : "crowns")"
    }

    /// What is still missing: "1 more crown", "30 more crowns".
    public static func more(_ count: Int) -> String {
        "\(count.formatted()) more \(count == 1 ? "crown" : "crowns")"
    }

    /// A crown glyph that carries its own tint whatever the control's.
    public static func glyphImage(_ configuration: UIImage.SymbolConfiguration? = nil) -> UIImage? {
        let image = UIImage.symbol(named: glyph, configuration: configuration)
        return image?.withTintColor(tint, renderingMode: .alwaysOriginal)
    }
}
