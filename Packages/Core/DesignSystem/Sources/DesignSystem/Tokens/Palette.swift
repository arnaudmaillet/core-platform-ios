import UIKit

/// THE BRAND PALETTE (#1124, accent chosen in #1169): the app's colours as
/// roles, never as hex at a call site.
///
/// ```
///   role                light      dark       IC light   IC dark
///   tint                D6337F     F37AB4     B0256A     F8ABCF
///   brandText           D6337F     F37AB4     B0256A     F8ABCF
///   primaryFill         D6337F     F37AB4
///   onPrimary           FFFFFF     2B0716
///   primaryFillPressed  C02A70     E86AA6
///   primaryContainer    FDE3EF     3A0A22     (text B8296C / F8ABCF)
///   secondary           6852C6     A78BFA     5C44B7     B59EFF
///   secondaryContainer  EFEEFF     211944     (text 6852C6 / A78BFA)
///   saveGold            A07800     FFC53D     (FFC53D over media)
/// ```
///
/// The rules the owner settled (#1124, 2026-10-13/14; #1169, 2026-10-14):
/// - **The accent is pink** (#1169, chosen on the simulator 2026-10-14):
///   `D6337F` in the light (4.53:1 on white — it reads as text too), `F37AB4`
///   in the dark (6.47:1 on black). Magenta (≈331°), clear of the points
///   heart's pink-red stop (≈348°), so an accent does not read as a like. It
///   replaces #1124's tangerine.
/// - **The UI is NEUTRAL** (#1169): neutrals stay the system's (labels,
///   backgrounds, fills, `Surface`), and so do the selected tab, secondary
///   buttons, chips, the segmented selection and in-text mentions (#1168).
///   This supersedes #1124's "the accent marks what is interactive or
///   selected".
/// - **The accent marks what matters**: a screen's one primary action, the
///   system controls (the app's tint — `AccentColor`, the window's
///   `tintColor` — so switches, the cursor and selection follow without
///   per-site code) and the unseen-story ring. Unread counts, the bell's
///   dot and the hearts stay the system red (`counter`, the owner's call
///   2026-10-14).
/// - **A filled button wears white** (`onPrimary`, 4.53:1 on the fill) in
///   the light, a dark ink on the brighter dark-mode fill.
/// - **Violet is secondary**: gems and secondary emphasis.
/// - **Dark mode is not an inversion**: the dark tint is brighter, not the
///   same hex. Every role also has an Increased Contrast value where its
///   contrast is close to the line.
/// - **The gradient is the brand's signature, kept to a few places**
///   (`brandGradient`): launch, onboarding, empty states, celebrations —
///   never on recurring chrome. Whether the story ring and a key moment's
///   hero button wear it is still compared on the device (`rules`).
public enum Palette {
    // MARK: - Primary: pink

    /// Interactive glyphs, text buttons, switches, selection: the app's tint.
    /// 4.53:1 on white, so it reads as text as well as a control.
    public static let tint = dynamic(light: 0xD6337F, dark: 0xF37AB4, lightIC: 0xB0256A, darkIC: 0xF8ABCF)

    /// Text that carries the accent (≥ 4.5:1): the tint itself, which
    /// already reads as text. Mentions and hashtags do NOT wear it (#1168).
    public static let brandText = dynamic(light: 0xD6337F, dark: 0xF37AB4, lightIC: 0xB0256A, darkIC: 0xF8ABCF)

    /// A prominent filled button's ground, an active chip.
    public static let primaryFill = dynamic(light: 0xD6337F, dark: 0xF37AB4)

    /// The label on `primaryFill`: white in the light (4.53:1), a deep ink
    /// on the brighter dark fill.
    public static let onPrimary = dynamic(light: 0xFFFFFF, dark: 0x2B0716)

    /// `primaryFill` pressed or highlighted.
    public static let primaryFillPressed = dynamic(light: 0xC02A70, dark: 0xE86AA6)

    /// A PROMINENT GLASS button's tint (the wallet's Claim, a country's
    /// Unlock): the deep pink in both appearances. ⚠️ The glass draws its
    /// label white and vibrant in the dark whatever ink is asked for, so the
    /// brighter dark-mode fill cannot be used there; white on this is 4.53:1.
    public static let prominentGlassTint = rgb(0xD6337F)

    /// A soft selected background, an info banner, a "New" badge.
    public static let primaryContainer = dynamic(light: 0xFDE3EF, dark: 0x3A0A22)

    /// Text on `primaryContainer`.
    public static let onPrimaryContainer = dynamic(light: 0xB8296C, dark: 0xF8ABCF)

    /// Every solid unread mark — the tab bar's badges, the Messages
    /// selector's, the bell's dot (#1169: one colour everywhere): the system
    /// red (the owner's call 2026-10-14), or the accent under the `.accent`
    /// rule to compare.
    public static var counter: UIColor {
        rules.counters == .accent ? tint : .systemRed
    }

    /// THE ICON'S GRADIENT (#1169, the owner's call 2026-10-14): pink at the
    /// bottom-left → orange at the top-right, as the icon runs, in the icon's
    /// own pink and orange made vivid enough to mark a pill. The icon's
    /// pastels (`F7BED2` → `FFBE7D`) carry a white digit at about 1.5:1; these
    /// carry it at about 1.9–2.6:1 — the owner chose the icon's tone over the
    /// system red badge's 3.55:1. The same in both appearances: a badge is a
    /// coloured mark on any ground. Worn by the unread pills on the inbox's avatars and by the
    /// unseen-story ring — NOT by the tab bar's badges, the selector's nor
    /// the bell's dot: those stay the solid red (`counter`).
    public static let accentGradient: [UIColor] = [rgb(0xF37AB4), rgb(0xFFA552)]

    /// `@mentions`, `#hashtags` and links in text on a plain surface (#1174,
    /// the owner 2026-10-14: "the pink as accent, used subtly and
    /// sparingly"): a quiet slate blue-grey, set apart from the words by its
    /// cool cast and the semibold — never the accent, never the system blue.
    /// 6.3:1 on white, 5.8:1 on the grouped grey; 7:1 and more in the dark.
    public static let entityInk = dynamic(light: 0x4F5F78, dark: 0x9AABC4, lightIC: 0x3E4C63, darkIC: 0xB4C2D6)

    /// Where `accentGradient` runs, in a layer's unit space.
    public static let accentGradientStart = CGPoint(x: 0, y: 1)
    public static let accentGradientEnd = CGPoint(x: 1, y: 0)

    // MARK: - Rules (#1169)

    /// How far the accent reaches (#1169, decided 2026-10-14: the UI is
    /// neutral). The defaults are the decision; the DEBUG flags still
    /// compare the two undecided ones on the device.
    public struct Rules: Equatable, Sendable {
        public enum Counters: String, Sendable { case accent, red }
        public enum Ring: String, Sendable { case accent, gradient }
        public enum Hero: String, Sendable { case accent, gradient }

        /// The selected tab in the label's colour, not the accent.
        public var selectedTabIsNeutral = true
        /// The solid unread marks: the system red (decided), or the accent to
        /// compare.
        public var counters = Counters.red
        /// The unseen-story ring: the icon's gradient (decided 2026-10-14), or
        /// the solid accent to compare.
        public var storyRing = Ring.gradient
        /// The hero button of a key moment (the wallet's Claim).
        public var heroButton = Hero.accent

        public init() {}
    }

    /// The rules the app runs. ⚠️ Written once at launch (`configure`)
    /// before any UI exists; tests read `resolve`, never this.
    nonisolated(unsafe) public static var rules = Rules()

    /// The rule flags a DEBUG launch asks for: `-theme-tab accent|neutral`,
    /// `-theme-counters accent|red`, `-theme-rings accent|gradient`,
    /// `-theme-hero accent|gradient`.
    public static func configure(arguments: [String]) {
        rules = resolve(arguments: arguments)
    }

    /// What `configure` would set, without setting it — what a test reads.
    public static func resolve(arguments: [String]) -> Rules {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        var configured = Rules()
        if let tab = value("-theme-tab") { configured.selectedTabIsNeutral = tab != "accent" }
        if let counters = value("-theme-counters").flatMap(Rules.Counters.init(rawValue:)) {
            configured.counters = counters
        }
        if let ring = value("-theme-rings").flatMap(Rules.Ring.init(rawValue:)) { configured.storyRing = ring }
        if let hero = value("-theme-hero").flatMap(Rules.Hero.init(rawValue:)) { configured.heroButton = hero }
        return configured
    }

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
        // ⚠️ SOLID NOW (#1169, the owner's call 2026-10-14: every heart the
        // system red). Two equal stops, so the heart's mask and layer — built
        // for a gradient — are untouched.
        let red = UIColor.systemRed.resolvedColor(with: traits)
        return [red, red]
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
