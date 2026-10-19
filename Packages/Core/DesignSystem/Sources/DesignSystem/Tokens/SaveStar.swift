import UIKit

/// The glyph for SAVING — the star, and its one gold (#1190). The save
/// star's single contract, as `LikesSymbol` is the heart's: every saved
/// star in the app is drawn from here, so a surface cannot pick a gold of its
/// own (the sound sheet's was another, the owner, 2026-10-15).
/// `SymbolContractTests` scans the sources for a gold or a filled star
/// chosen anywhere else.
public enum SaveStar {
    /// The star, outline: not saved.
    public static let outlineGlyph = AppSymbol.save.rawValue
    /// The star, filled: saved.
    public static let glyph = AppSymbol.saved.rawValue
    /// The saved star's gold: the full-screen post's, the reference
    /// (#1188), the same in both appearances.
    public static var tint: UIColor { Palette.saveGold }

    /// The glyph's name for a state.
    public static func symbol(saved: Bool) -> String { saved ? glyph : outlineGlyph }

    /// The star for a state: outline as a TEMPLATE at rest (the control's ink
    /// draws it), filled in its gold once saved, carrying its own colour.
    public static func image(saved: Bool, _ configuration: UIImage.SymbolConfiguration? = nil) -> UIImage? {
        let image = UIImage.symbol(named: symbol(saved: saved), configuration: configuration)
        return saved
            ? image?.withTintColor(tint, renderingMode: .alwaysOriginal)
            : image?.withRenderingMode(.alwaysTemplate)
    }
}
