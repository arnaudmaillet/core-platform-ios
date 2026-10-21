import UIKit

/// A symbol for a BAR, drawn into a bitmap (#1178, #1191, #1501): a bar
/// item re-renders a symbol image in its own mode and drops a palette — the
/// tab bar's badge came out in the system red whatever the palette said — so
/// the badged bell and the badged tab glyphs are drawn, not handed over as
/// symbols.
public enum BarSymbol {
    /// `symbol` drawn for `traits`, in the applied accent theme.
    ///
    /// ⚠️ PASS THE WINDOW'S TRAITS (#1501). A light and a dark bitmap in an
    /// image asset let the bar pick the variant, and it picked by iOS's
    /// appearance rather than the app's: with iOS dark and the app set to
    /// Light the bell and the badged tabs were drawn white on the light bars.
    /// One bitmap, resolved for the window — whose `overrideUserInterfaceStyle`
    /// is the app's choice — is what the bar shows; the caller bakes again
    /// when those traits change.
    @MainActor
    public static func baked(_ symbol: UIImage, traits: UITraitCollection) -> UIImage {
        let format = UIGraphicsImageRendererFormat(for: traits)
        format.opaque = false
        // The accent is the applied theme's (#1379): a bitmap re-resolves
        // nothing, so a theme change bakes it anew.
        let drawing = traits.modifyingTraits { $0.accentTheme = AccentThemePreference.applied }
        let bitmap = UIGraphicsImageRenderer(size: symbol.size, format: format).image { _ in
            drawing.performAsCurrent { symbol.draw(at: .zero) }
        }
        return bitmap
            .withBaselineOffset(fromBottom: symbol.baselineOffsetFromBottom ?? 0)
            .withRenderingMode(.alwaysOriginal)
    }
}
