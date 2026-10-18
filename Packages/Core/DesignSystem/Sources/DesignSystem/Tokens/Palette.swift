import UIKit

/// THE BRAND PALETTE (#1124, accent chosen in #1169): the app's colours as
/// roles, never as hex at a call site.
///
/// ```
///   role                light      dark       IC light   IC dark
///   tint                F37AB4     F37AB4     B0256A     F8ABCF
///   brandText           F37AB4     F37AB4     B0256A     F8ABCF
///   primaryFill         F37AB4     F37AB4
///   onPrimary           FFFFFF     2B0716
///   primaryFillPressed  E86AA6     E86AA6
///   primaryContainer    FDE3EF     3A0A22     (text B8296C / F8ABCF)
///   secondary           6852C6     A78BFA     5C44B7     B59EFF
///   secondaryContainer  EFEEFF     211944     (text 6852C6 / A78BFA)
///   saveGold            FFC53D     FFC53D     (one gold, #1190)
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
///   per-site code) and the unseen-story ring. The hearts are the pink;
///   unread counts and the bell's dot the violet (`counter`, #1178, the
///   owner 2026-10-15) — the system red is for errors and destruction only.
/// - **A filled button wears white** (`onPrimary`, 4.53:1 on the fill) in
///   the light, a dark ink on the brighter dark-mode fill.
/// - **Violet is secondary** (#1176, the icon redrawn pink → violet on
///   2026-10-14): the accent's companion — gems, secondary emphasis, the
///   gradients' far stop and, greyed, the ink of links and tokens
///   (`entityInk`). Filled buttons stay pink.
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
    /// ⚠️ LIGHTER IN THE LIGHT since #1190 (the owner, 2026-10-15: the dark
    /// theme's pink, `F37AB4`, in both appearances): about 2.3:1 on white, a
    /// mark rather than text strength — chosen knowingly. Increased Contrast
    /// keeps the deep pink (`B0256A`, 6:1).
    public static let tint = dynamic(light: 0xF37AB4, dark: 0xF37AB4, lightIC: 0xB0256A, darkIC: 0xF8ABCF)

    /// Text that carries the accent (≥ 4.5:1): the tint itself, which
    /// already reads as text. Mentions and hashtags do NOT wear it (#1168).
    public static let brandText = dynamic(light: 0xF37AB4, dark: 0xF37AB4, lightIC: 0xB0256A, darkIC: 0xF8ABCF)

    /// A prominent filled button's ground, an active chip.
    public static let primaryFill = dynamic(light: 0xF37AB4, dark: 0xF37AB4, lightIC: 0xB0256A, darkIC: 0xF8ABCF)

    /// The label on `primaryFill`: white in the light (4.53:1), a deep ink
    /// on the brighter dark fill.
    public static let onPrimary = dynamic(light: 0xFFFFFF, dark: 0x2B0716)

    /// `primaryFill` pressed or highlighted.
    public static let primaryFillPressed = dynamic(light: 0xE86AA6, dark: 0xE86AA6, lightIC: 0x9C1F5E, darkIC: 0xE86AA6)

    /// A PROMINENT GLASS button's tint (the wallet's Claim, a country's
    /// Unlock): the primary pink in both appearances (#1190). ⚠️ The glass
    /// draws its label white and vibrant whatever ink is asked for.
    public static let prominentGlassTint = rgb(0xF37AB4)

    /// A soft selected background, an info banner, a "New" badge.
    public static let primaryContainer = dynamic(light: 0xFDE3EF, dark: 0x3A0A22)

    /// The prominent button's fill (#1178, the owner 2026-10-15: "pink, a
    /// pink-to-white gradient"): the tint at the bottom-left lightening
    /// toward a pale pink at the top-right, under white words — 4.53:1 where
    /// the words start, lighter toward the far corner. The same in both
    /// appearances.
    public static let primaryGradient: [UIColor] = [rgb(0xF37AB4), rgb(0xFAC8DF)]

    /// Text on `primaryContainer`.
    public static let onPrimaryContainer = dynamic(light: 0xB8296C, dark: 0xF8ABCF)

    /// Every solid unread mark — the tab bar's badges, the Messages
    /// selector's, the bell's dot, a menu row's count (#1169: one colour
    /// everywhere): the violet (#1178, the owner 2026-10-15: "UIKit's reds
    /// in violet"), the same in both appearances, where a white count reads
    /// at 4.5:1. The `.accent` and `.red` rules compare the pink and the
    /// system red.
    public static var counter: UIColor {
        switch rules.counters {
        case .violet: counterViolet
        case .accent: tint
        case .red: .systemRed
        }
    }

    static let counterViolet = rgb(0x7C5CF0)

    /// THE ICON'S GRADIENT (#1169; pink → violet since the icon was redrawn,
    /// #1176): pink at the bottom-left → violet at the top-right, as the icon
    /// runs, in the icon's own hues made vivid enough to mark a pill — the
    /// dark tint and the dark secondary. A white digit reads at about
    /// 2.7:1 on both stops (the owner chose the icon's tone over the system
    /// red badge's 3.55:1). The same in both appearances: a badge is a
    /// coloured mark on any ground. Worn by the unread pills on the inbox's
    /// avatars and by the unseen-story ring — NOT by the tab bar's badges, the
    /// selector's nor the bell's dot: those stay solid (`counter`).
    public static let accentGradient: [UIColor] = [rgb(0xF37AB4), rgb(0xA78BFA)]

    /// `@mentions`, `#hashtags` and links in text on a plain surface (#1174,
    /// the owner 2026-10-14: "the pink as accent, used subtly and
    /// sparingly"): a greyed violet — the secondary, quieted (#1176) — set
    /// apart from the words by its cast and the semibold; never the accent,
    /// never the system blue. 6.3:1 on white, 5.8:1 on the grouped grey;
    /// 7:1 and more in the dark.
    public static let entityInk = dynamic(light: 0x645A82, dark: 0xAFA3CC, lightIC: 0x4F4669, darkIC: 0xC3B9DD)

    /// Where `accentGradient` runs, in a layer's unit space.
    public static let accentGradientStart = CGPoint(x: 0, y: 1)
    public static let accentGradientEnd = CGPoint(x: 1, y: 0)

    // MARK: - Rules (#1169)

    /// How far the accent reaches (#1169, decided 2026-10-14: the UI is
    /// neutral). The defaults are the decision; the DEBUG flags still
    /// compare the two undecided ones on the device.
    public struct Rules: Equatable, Sendable {
        public enum Counters: String, Sendable { case violet, accent, red }
        public enum Ring: String, Sendable { case accent, gradient }
        public enum Hero: String, Sendable { case accent, gradient }

        /// The selected tab in the label's colour, not the accent.
        public var selectedTabIsNeutral = true
        /// The solid unread marks: the system red (decided), or the accent to
        /// compare.
        public var counters = Counters.violet
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
    /// `-theme-counters violet|accent|red`, `-theme-rings accent|gradient`,
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

    // MARK: - The loader (#1329)

    /// The branded loader's four pieces, one solid tone each, from the pink to
    /// the violet clockwise from the top-left: `tint` → `secondary` (dark)
    /// with two even steps between. The same in both appearances — the mark
    /// is a logo, not text (owner, 2026-10-17). Read through `AppLoaderView`.
    public static let loaderTones: [UIColor] = [
        rgb(0xF37AB4), rgb(0xA78BFA), rgb(0xC08BE6), rgb(0xD98AD0),
    ]

    // MARK: - Economy

    /// The saved star (#1128): gold, the 收藏 convention — ONE gold, the
    /// full-screen post's, in both appearances and over media (#1188, #1190:
    /// the owner's reference). Read through `SaveStar`, never directly.
    public static let saveGold = rgb(0xFFC53D)

    /// The same gold — kept as a name for the media surfaces that said so.
    public static var saveGoldOnMedia: UIColor { saveGold }

    /// The Points heart's gradient stops (#1124, decision 7), bottom-left to
    /// top-right: yellow → orange → pink. In the light the yellow start is
    /// the deeper tangerine instead — yellow is 1.51:1 on white, under the
    /// 3:1 a meaningful glyph needs, and it keeps yellow and gold for the
    /// saved star alone. Drawn by the custom heart (#1128), as a mask over a
    /// gradient layer: SF Symbols do not draw a three-stop gradient.
    public static func pointsGradient(for traits: UITraitCollection) -> [UIColor] {
        // ⚠️ SOLID: the pink (#1178, the owner 2026-10-15, after a pink →
        // violet pass). Two equal stops, so the heart's mask and layer — built
        // for a gradient — are untouched.
        let pink = tint.resolvedColor(with: traits)
        return [pink, pink]
    }

    /// The icon's own gradient, pink → violet (#1176), deep enough to carry a
    /// white label, for brand moments only (splash, onboarding, empty-state
    /// art, the Shop's hero art, the wallet's hero rule).
    public static let brandGradient: [UIColor] = [rgb(0xE0559A), rgb(0x7C5CF0)]

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
