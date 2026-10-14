import UIKit

/// THE BRAND PALETTE (#1124): the app's colours, from its icon — the accent
/// first, violet second — as roles, never as hex at a call site.
///
/// ⚠️ THE ACCENT IS A THEME (#1169). Its roles (`tint` … `onPrimaryContainer`)
/// read the running `theme`; `-theme current|flame|raspberry|pink|orchid`
/// (DEBUG) compares the candidates on a device, and Release runs `shipped`.
/// The table below is `current`'s. How much of the UI the accent reaches is
/// the `rules` (#1169, decided 2026-10-14): the UI is NEUTRAL — the selected
/// tab, secondary buttons, chips and in-text mentions wear the label colour —
/// and the accent marks a screen's one primary action, the system controls
/// (the window tint), unread counters and the unseen-story ring.
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
/// - **The accent is the app's tint** (`AccentColor`, the window's
///   `tintColor`), so every system control and every `.tintColor` read
///   follows without per-site code. ⚠️ #1169 (pending the device decision)
///   no longer has it mark every selection: the selected tab is neutral
///   (`rules`).
/// - **Tangerine's filled button wears a dark ink** (`onPrimary`), not white:
///   white on the vivid fill is 2.31:1 and fails, and darkening the fill
///   until white passes turns the brand brown. The deeper candidates wear
///   white.
/// - **Violet is secondary**: gems and secondary emphasis.
/// - **Dark mode is not an inversion**: the dark tint is brighter, not the
///   same hex. Every role also has an Increased Contrast value where its
///   contrast is close to the line.
/// - **The gradient is for brand moments only** (`brandGradient`): never on
///   recurring chrome — like buttons, tab items — where it would read as
///   Instagram's. #1169 puts the unseen-story ring and the hero button to a
///   device comparison (`rules.storyRing`, `rules.heroButton`).
public enum Palette {
    // MARK: - Primary: the theme's accent

    /// Interactive glyphs, text buttons, switches, selection: the app's tint.
    /// Held to the 3:1 of a control, not the 4.5:1 of body text (`brandText`
    /// is). Today's tangerine is 4.03:1 on white, as `systemBlue`'s 4.02:1.
    public static var tint: UIColor { theme.tint }

    /// Text that carries the accent: the tint, deepened in the light until it
    /// reads as text (≥ 4.5:1 on white).
    public static var brandText: UIColor { theme.brandText }

    /// A prominent filled button's ground, an active chip.
    public static var primaryFill: UIColor { theme.primaryFill }

    /// The label on `primaryFill`. Tangerine wears a warm near-black (white
    /// on it is 2.31:1); a deeper accent wears white.
    public static var onPrimary: UIColor { theme.onPrimary }

    /// `primaryFill` pressed or highlighted.
    public static var primaryFillPressed: UIColor { theme.primaryFillPressed }

    /// A PROMINENT GLASS button's tint (the wallet's Claim, a country's
    /// Unlock): one deep accent in both appearances. ⚠️ The glass draws its
    /// label white and vibrant in the dark whatever ink is asked for, so the
    /// light dark-mode fill cannot be used there.
    public static var prominentGlassTint: UIColor { theme.prominentGlassTint }

    /// A soft selected background, an info banner, a "New" badge.
    public static var primaryContainer: UIColor { theme.primaryContainer }

    /// Text on `primaryContainer`.
    public static var onPrimaryContainer: UIColor { theme.onPrimaryContainer }

    /// Every unread count — the tab bar's badges, the Messages selector's,
    /// an inbox row's (#1169: one colour everywhere): the accent, or the
    /// system red under the `.red` rule.
    public static var counter: UIColor {
        rules.counters == .accent ? theme.tint : .systemRed
    }

    // MARK: - Theme (#1169)

    /// The accent roles, as one value: the theme the app runs. Set ONCE, at
    /// launch, before any screen reads a role (`-theme <name>`, DEBUG only);
    /// Release always runs `shipped`.
    public struct Theme: Sendable {
        public let name: String
        public let tint: UIColor
        public let brandText: UIColor
        public let primaryFill: UIColor
        public let onPrimary: UIColor
        public let primaryFillPressed: UIColor
        public let prominentGlassTint: UIColor
        public let primaryContainer: UIColor
        public let onPrimaryContainer: UIColor
    }

    /// How the accent is used (#1169, decided 2026-10-14: the UI is neutral,
    /// the accent kept for what matters). Each rule has a DEBUG flag so the
    /// candidates can be compared both ways on the device.
    public struct Rules: Equatable, Sendable {
        public enum Counters: String, Sendable { case accent, red }
        public enum Ring: String, Sendable { case accent, gradient }
        public enum Hero: String, Sendable { case accent, gradient }

        /// The selected tab in the label's colour, not the accent.
        public var selectedTabIsNeutral = true
        public var counters = Counters.accent
        /// The unseen-story ring: the solid accent, or the brand gradient.
        public var storyRing = Ring.accent
        /// The hero button of a key moment (the wallet's Claim).
        public var heroButton = Hero.accent

        public init() {}
    }

    /// The theme the app runs. ⚠️ Written once at launch (`apply(themeNamed:)`)
    /// before any UI exists; tests set it and put it back.
    nonisolated(unsafe) public static var theme: Theme = shipped
    nonisolated(unsafe) public static var rules = Rules()

    /// What Release builds.
    public static let shipped = current

    /// Every candidate, by its launch-argument name.
    public static let themes: [Theme] = [current, flame, raspberry, pink, orchid]

    /// Today's tangerine (#1124): the reference.
    public static let current = Theme(
        name: "current",
        tint: dynamic(light: 0xC76300, dark: 0xFFAD66, lightIC: 0x8B4600, darkIC: 0xFFD0AA),
        brandText: dynamic(light: 0xB75F00, dark: 0xFFAD66, lightIC: 0x8B4600, darkIC: 0xFFD0AA),
        primaryFill: dynamic(light: 0xFF8D28, dark: 0xFFAD66),
        onPrimary: dynamic(light: 0x2B1607, dark: 0x2B1607),
        primaryFillPressed: dynamic(light: 0xF1800E, dark: 0xF09F58),
        prominentGlassTint: rgb(0xC76300),
        primaryContainer: dynamic(light: 0xFFECE0, dark: 0x331B08),
        onPrimaryContainer: dynamic(light: 0x9F5100, dark: 0xFFA664)
    )

    /// The gradient's orange end, deepened (3.56:1 on white; white on it for
    /// a large bold label). Same luminance as `systemRed`.
    public static let flame = Theme(
        name: "flame",
        tint: dynamic(light: 0xE85A0C, dark: 0xFF7A33, lightIC: 0xB23F00, darkIC: 0xFFB08A),
        brandText: dynamic(light: 0xC24A00, dark: 0xFF8A4D, lightIC: 0x9A3800, darkIC: 0xFFB08A),
        primaryFill: dynamic(light: 0xE85A0C, dark: 0xFF7A33),
        onPrimary: dynamic(light: 0xFFFFFF, dark: 0x2B1004),
        primaryFillPressed: dynamic(light: 0xD14F08, dark: 0xF06B25),
        prominentGlassTint: rgb(0xE85A0C),
        primaryContainer: dynamic(light: 0xFFE9DE, dark: 0x3A1A0A),
        onPrimaryContainer: dynamic(light: 0xB23F00, dark: 0xFF9A66)
    )

    /// The gradient's rose middle, deepened (4.68:1 on white).
    public static let raspberry = Theme(
        name: "raspberry",
        tint: dynamic(light: 0xD1376F, dark: 0xFF7AA8, lightIC: 0xA0234F, darkIC: 0xFFB3CC),
        brandText: dynamic(light: 0xC02A60, dark: 0xFF8FB6, lightIC: 0xA0234F, darkIC: 0xFFB3CC),
        primaryFill: dynamic(light: 0xD1376F, dark: 0xFF7AA8),
        onPrimary: dynamic(light: 0xFFFFFF, dark: 0x2B0716),
        primaryFillPressed: dynamic(light: 0xBA2E62, dark: 0xF06A99),
        prominentGlassTint: rgb(0xD1376F),
        primaryContainer: dynamic(light: 0xFFE6EF, dark: 0x3A0A1C),
        onPrimaryContainer: dynamic(light: 0xA0234F, dark: 0xFF8FB6)
    )

    /// The owner's proposal (2026-10-14), the gradient's pink (3.24:1 on
    /// white): text takes the deeper `D6337F` (4.53:1). Magenta (≈331°),
    /// clear of the points heart's pink-red stop (≈348°).
    public static let pink = Theme(
        name: "pink",
        tint: dynamic(light: 0xEE56A0, dark: 0xF37AB4, lightIC: 0xC2307A, darkIC: 0xF8ABCF),
        brandText: dynamic(light: 0xD6337F, dark: 0xF8ABCF, lightIC: 0xB0256A, darkIC: 0xFBC8E0),
        primaryFill: dynamic(light: 0xEE56A0, dark: 0xF37AB4),
        onPrimary: dynamic(light: 0xFFFFFF, dark: 0x2B0716),
        primaryFillPressed: dynamic(light: 0xD94690, dark: 0xE86AA6),
        prominentGlassTint: rgb(0xD6337F),
        primaryContainer: dynamic(light: 0xFDE3EF, dark: 0x3A0A22),
        onPrimaryContainer: dynamic(light: 0xB8296C, dark: 0xF8ABCF)
    )

    /// The gradient's orchid end, deepened (5.91:1 on white). With it, gems
    /// (violet `secondary`) share the accent's family.
    public static let orchid = Theme(
        name: "orchid",
        tint: dynamic(light: 0x8A3FC0, dark: 0xC98BF0, lightIC: 0x6E2BA0, darkIC: 0xE0B8FF),
        brandText: dynamic(light: 0x8A3FC0, dark: 0xC98BF0, lightIC: 0x6E2BA0, darkIC: 0xE0B8FF),
        primaryFill: dynamic(light: 0x8A3FC0, dark: 0xC98BF0),
        onPrimary: dynamic(light: 0xFFFFFF, dark: 0x1E0B2B),
        primaryFillPressed: dynamic(light: 0x7733AA, dark: 0xB97AE0),
        prominentGlassTint: rgb(0x8A3FC0),
        primaryContainer: dynamic(light: 0xF3E8FC, dark: 0x2A1240),
        onPrimaryContainer: dynamic(light: 0x6E2BA0, dark: 0xD4A6F5)
    )

    /// The theme and rules a launch asks for: `-theme <name>`, and the rule
    /// flags `-theme-tab accent|neutral`, `-theme-counters accent|red`,
    /// `-theme-rings accent|gradient`, `-theme-hero accent|gradient`. An
    /// unknown name keeps the shipped theme.
    public static func configure(arguments: [String]) {
        (theme, rules) = resolve(arguments: arguments)
    }

    /// What `configure` would set, without setting it — what a test reads.
    public static func resolve(arguments: [String]) -> (theme: Theme, rules: Rules) {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let chosen = value("-theme").flatMap { name in themes.first { $0.name == name } } ?? shipped
        var configured = Rules()
        if let tab = value("-theme-tab") { configured.selectedTabIsNeutral = tab != "accent" }
        if let counters = value("-theme-counters").flatMap(Rules.Counters.init(rawValue:)) {
            configured.counters = counters
        }
        if let ring = value("-theme-rings").flatMap(Rules.Ring.init(rawValue:)) { configured.storyRing = ring }
        if let hero = value("-theme-hero").flatMap(Rules.Hero.init(rawValue:)) { configured.heroButton = hero }
        return (chosen, configured)
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
