import UIKit

/// THE BRAND PALETTE (#1124): the app's colours, from its icon — tangerine
/// first, violet second — as roles, never as hex at a call site.
///
/// ```
///   role                light      dark       IC light   IC dark
///   tint                C76300     FFAD66     8B4600     FFD0AA
///   brandText           B75F00     FFAD66     8B4600     FFD0AA
///   primaryFill         FF8D28     FFAD66
///   onPrimary           2B1607     2B1607
///   primaryFillPressed  F1800E     F09F58
///   primaryContainer    FFECE0     331B08     (text 9F5100 / FFA664)
///   secondary           6852C6     A78BFA     5C44B7     B59EFF
///   secondaryContainer  EFEEFF     211944     (text 6852C6 / A78BFA)
///   saveGold            A07800     FFC53D     (FFC53D over media)
/// ```
///
/// The rules the owner settled (2026-10-13/14, #1124):
/// - **Neutrals stay the system's** (labels, backgrounds, fills, `Surface`):
///   they already adapt to dark mode, Increased Contrast and glass. This type
///   holds only the HUES.
/// - **Tangerine marks what is interactive or selected.** It is the app's
///   tint (`AccentColor`, the window's `tintColor`), so every system control
///   and every `.tintColor` read follows without per-site code.
/// - **A filled button wears a dark ink** (`onPrimary`), not white: white on
///   the vivid fill is 2.31:1 and fails, and darkening the fill until white
///   passes turns the brand brown.
/// - **Violet is secondary**: gems and secondary emphasis.
/// - **Dark mode is not an inversion**: the dark tint is brighter, not the
///   same hex. Every role also has an Increased Contrast value where its
///   contrast is close to the line.
/// - **The gradient is for brand moments only** (`brandGradient`): never on
///   recurring chrome — rings, like buttons, tab items — where it would read
///   as Instagram's.
public enum Palette {
    // MARK: - Primary: tangerine

    /// Interactive glyphs, text buttons, switches, selection: the app's tint.
    /// 4.03:1 on white, as `systemBlue`'s 4.02:1 — a tint is held to the 3:1
    /// of a control, not the 4.5:1 of body text (`brandText` is).
    public static let tint = dynamic(light: 0xC76300, dark: 0xFFAD66, lightIC: 0x8B4600, darkIC: 0xFFD0AA)

    /// @mentions, #hashtags and links inside body text: the tint, deepened
    /// in the light until it reads as text (4.52:1 on white).
    public static let brandText = dynamic(light: 0xB75F00, dark: 0xFFAD66, lightIC: 0x8B4600, darkIC: 0xFFD0AA)

    /// A prominent filled button's ground, an active chip.
    public static let primaryFill = dynamic(light: 0xFF8D28, dark: 0xFFAD66)

    /// The label on `primaryFill`: a warm near-black (7.45:1 light, 9.36:1
    /// dark).
    public static let onPrimary = dynamic(light: 0x2B1607, dark: 0x2B1607)

    /// `primaryFill` pressed or highlighted.
    public static let primaryFillPressed = dynamic(light: 0xF1800E, dark: 0xF09F58)

    /// A PROMINENT GLASS button's tint (the wallet's Claim, a country's
    /// Unlock): the deep tangerine in both appearances. ⚠️ The glass draws
    /// its label white and vibrant in the dark whatever ink is asked for, so
    /// the dark `primaryFill` (white on it 1.9:1) cannot be used there; white
    /// on this is 4.03:1 in either appearance.
    public static let prominentGlassTint = rgb(0xC76300)

    /// A soft selected background, an info banner, a "New" badge.
    public static let primaryContainer = dynamic(light: 0xFFECE0, dark: 0x331B08)

    /// Text on `primaryContainer`.
    public static let onPrimaryContainer = dynamic(light: 0x9F5100, dark: 0xFFA664)

    // MARK: - Secondary: violet

    /// Gems and secondary emphasis. A white label on it passes too (5.82:1).
    public static let secondary = dynamic(light: 0x6852C6, dark: 0xA78BFA, lightIC: 0x5C44B7, darkIC: 0xB59EFF)

    /// The gem shop's shelf ground, a gem badge.
    public static let secondaryContainer = dynamic(light: 0xEFEEFF, dark: 0x211944)

    /// Text on `secondaryContainer`.
    public static let onSecondaryContainer = dynamic(light: 0x6852C6, dark: 0xA78BFA)

    // MARK: - Economy

    /// The saved star (#1128): gold, the 收藏 convention. Deepened in the
    /// light, where the vivid gold is 1.58:1 on white.
    public static let saveGold = dynamic(light: 0xA07800, dark: 0xFFC53D)

    /// The saved star over a photograph or a video, in either appearance.
    public static let saveGoldOnMedia = rgb(0xFFC53D)

    /// The Points heart's gradient stops (#1124, decision 7), bottom-left to
    /// top-right: yellow → orange → pink. In the light the yellow start is
    /// the deeper tangerine instead — yellow is 1.51:1 on white, under the
    /// 3:1 a meaningful glyph needs, and it keeps yellow and gold for the
    /// saved star alone. Drawn by the custom heart (#1128), as a mask over a
    /// gradient layer: SF Symbols do not draw a three-stop gradient.
    public static func pointsGradient(for traits: UITraitCollection) -> [UIColor] {
        let stops: [UIColor] = traits.userInterfaceStyle == .dark
            ? [.systemYellow, .systemOrange, .systemPink]
            : [rgb(0xC76300), .systemOrange, .systemPink]
        return stops.map { $0.resolvedColor(with: traits) }
    }

    /// The icon's own gradient, orchid → tangerine, for brand moments only
    /// (splash, onboarding, empty-state art, the Shop's hero art).
    public static let brandGradient: [UIColor] = [rgb(0xB959DD), rgb(0xFF8D28)]

    // MARK: - Building

    /// A colour from its sRGB hex.
    static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    /// A role that resolves per appearance and contrast setting; without an
    /// Increased Contrast value it keeps its ordinary one.
    static func dynamic(light: UInt32, dark: UInt32, lightIC: UInt32? = nil, darkIC: UInt32? = nil) -> UIColor {
        let colours = (
            light: rgb(light), dark: rgb(dark),
            lightIC: rgb(lightIC ?? light), darkIC: rgb(darkIC ?? dark)
        )
        return UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let isHigh = traits.accessibilityContrast == .high
            switch (isDark, isHigh) {
            case (false, false): return colours.light
            case (true, false): return colours.dark
            case (false, true): return colours.lightIC
            case (true, true): return colours.darkIC
            }
        }
    }
}

/// HOW A WARNING IS DRAWN (#1124, the owner's call 2026-10-14): a yellow
/// glyph, and the words in a neutral ink.
///
/// Orange is the brand's tint, so a warning in orange reads as a button; and
/// `systemYellow` as text is about 1.5:1 on white, unreadable. So the colour
/// rides the GLYPH alone — the triangle says "warning" by its shape too — and
/// the text stays the row's own secondary ink.
public enum Warning {
    /// A warning glyph's colour.
    public static let glyphTint: UIColor = .systemYellow
    /// A warning's words.
    public static let textColor: UIColor = .secondaryLabel
    /// The glyph a warning wears beside its words.
    public static let symbol = "exclamationmark.triangle.fill"

    /// `text` led by the yellow triangle, the words in the neutral ink — for
    /// a label that has room for one line and no image view of its own.
    public static func note(_ text: String, font: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let configuration = UIImage.SymbolConfiguration(font: font, scale: .small)
        if let glyph = UIImage(systemName: symbol, withConfiguration: configuration)?
            .withTintColor(glyphTint, renderingMode: .alwaysOriginal) {
            result.append(NSAttributedString(attachment: NSTextAttachment(image: glyph)))
            result.append(NSAttributedString(string: " "))
        }
        result.append(NSAttributedString(string: text))
        result.addAttributes([.font: font, .foregroundColor: textColor], range: NSRange(location: 0, length: result.length))
        return result
    }
}
