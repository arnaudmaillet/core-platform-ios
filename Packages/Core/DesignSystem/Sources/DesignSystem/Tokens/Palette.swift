import UIKit

/// THE BRAND PALETTE (#1124, accent chosen in #1169): the app's colours as
/// roles, never as hex at a call site — nor here: every role derives from
/// `BrandTheme.current` (#2062), the one place the brand's raw colours live.
/// Changing the theme is writing a new `BrandTheme`; the roles keep their
/// names and their meaning.
///
/// ```
///   role                light      dark       IC light   IC dark    (contrast, WCAG 2.x)
///   tint                FF1358     FF1358     C6003A     FF5C8C     3.83 white · 5.49 black · IC 6.07 · 7.16
///   brandText           EB0045     FF1358     C6003A     FF5C8C     4.55 white · 5.49 black · IC 6.07 · 7.16
///   primaryFill         FF1358     FF1358     C6003A     C6003A     white label 3.83 · IC 6.07
///   onPrimary           FFFFFF     FFFFFF
///   primaryFillPressed  DA0040     DA0040     AA0032     DA0040     white label 5.18 · IC 7.62 · 5.18
///   primaryContainer    FFE3EB     3D0515     (text B20034 / FF7DA3: 5.93 · 7.08)
///   counter             FF1358     FF1358     C6003A     C6003A     white count 3.83 · IC 6.07
///   entityInk           5E5E66     AEAEB4     48484F     C8C8CD
///   gem                 F5C000     FFE600     A87C00     FFE600
///   gemText             8A6400     FFE600     7A5800     FFE600
///   gemGround           FFE600     FFE600     (a wash, at the bubble's alpha)
///   saveGold            FFC53D     FFC53D     (one gold, #1190)
///   brandGradient       7235FF 0 · 16FFCB 1   (IC: 7235FF · 009E7B, 3.05 on F2F2F7)
///   storyRingGradient   the signature, with its IC stops
///   (theme.accent       009E7B     16FFCB     008567     16FFCB     no role: not a UI colour, #2282 § 3)
/// ```
///
/// The rules the owner settled (#1124, #1169, #1178, #1190; #2062 on
/// 2026-11-02; #2282 on 2026-11-11):
/// - **The primary is `FF1358`, almost everywhere** (#2282), the same in
///   both appearances — 3.83:1 on white, 5.49:1 on black: past a glyph's
///   3:1 everywhere, and a filled button's semibold white label at 3.83.
///   Text in it wears `brandText`, deeper in the light (`EB0045`, 4.55:1).
///   Increased Contrast deepens both in the light (`C6003A`, 6.1:1) and
///   lifts them in the dark (`FF5C8C`, 7.2:1). It replaced #2062's
///   raspberry `EC1C75`.
/// - **The UI is NEUTRAL** (#1169): neutrals stay the system's (labels,
///   backgrounds, fills, `Surface`), and so do the selected tab, secondary
///   buttons, chips, the segmented selection and in-text mentions (#1168).
/// - **The primary marks what matters**: a screen's one primary action, the
///   system controls (the app's tint — `AccentColor`, the window's
///   `tintColor` — so switches, the cursor and selection follow without
///   per-site code), the hearts and every unread mark (`counter`). The
///   system red is for errors and destruction only.
/// - **Every pill and badge is the solid primary** (the owner, 2026-11-02):
///   never a gradient, under a white count.
/// - **A filled button wears white** (`onPrimary`) in both appearances.
/// - **The mint is the brand's second colour, not a UI colour** (#2282
///   § 3): the icon, the launch logo and the signature's end. The theme
///   holds it (`accent`, with a deep mint for light grounds) but no role
///   reads it. The violet appears only inside the signature gradient
///   (#2071: the gems wear the crown's yellow — `gem`, `gemText`,
///   `gemGround`). Links, mentions and hashtags are a neutral grey
///   (`entityInk`).
/// - **Dark mode is not an inversion.** Every role has an Increased
///   Contrast value where its contrast is close to the line.
/// - **The signature gradient is kept to a few places** (`brandGradient`,
///   violet `7235FF` → mint `16FFCB`, #2282): the unseen-story ring
///   (`storyRingGradient`, #2089) and the loader (`loaderGradient`, #2147).
///   White text never sits over its mint half (1.30:1), so no button wears
///   it.
public enum Palette {
    // MARK: - Primary: FF1358

    /// Interactive glyphs, text buttons, switches, selection: the app's tint.
    /// The same `FF1358` in both appearances (3.83:1 on white, 5.49:1 on
    /// black, past a glyph's 3:1); Increased Contrast takes it past 6:1 on
    /// either.
    public static let tint = dynamic(theme.primary)

    /// Text that carries the primary (#2282): the primary's text shade,
    /// deeper in the light (`EB0045`, 4.55:1 on white), the primary itself
    /// in the dark (5.49:1 on black). Mentions and hashtags do NOT wear it
    /// (#1168).
    public static let brandText = dynamic(theme.primaryText)

    /// A prominent filled button's ground, an active chip.
    public static let primaryFill = dynamic(theme.primaryFill)

    /// The label on `primaryFill`: white in both appearances (3.83:1, a
    /// semibold label at the button's size; 6.07:1 on the Increased
    /// Contrast fill).
    public static let onPrimary = dynamic(theme.onPrimary)

    /// `primaryFill` pressed or highlighted.
    public static let primaryFillPressed = dynamic(theme.primaryPressed)

    /// A PROMINENT GLASS button's tint (the wallet's Claim, a country's
    /// Unlock): the primary in both appearances. ⚠️ The glass
    /// draws its label white and vibrant whatever ink is asked for.
    public static let prominentGlassTint = dynamic(theme.primarySolid)

    /// A soft selected background, an info banner, a "New" badge.
    public static let primaryContainer = dynamic(theme.primaryContainer)

    /// The prominent button's fill: the solid primary in both appearances,
    /// under white words (#1178; solid since the owner's 2026-10-23 "no
    /// more white gradient, plain colours").
    public static let prominentFill = dynamic(theme.primarySolid)

    /// Text on `primaryContainer`.
    public static let onPrimaryContainer = dynamic(theme.onPrimaryContainer)

    /// Every unread mark, pill and badge — the tab bar's badges, the Messages
    /// selector's, the bell's dot, the inbox's unread pills, the profile
    /// switcher's counts (#2062: solid, never a gradient): the primary, the
    /// same in both appearances, under a white count (3.83:1; 6.07:1 with
    /// Increased Contrast). The `.red` rule compares the system red.
    public static var counter: UIColor {
        switch rules.counters {
        case .accent: counterMark
        case .red: .systemRed
        }
    }

    /// The solid unread mark's colour.
    static let counterMark = dynamic(theme.counter)

    /// `@mentions`, `#hashtags` and links in text on a plain surface (#1174;
    /// a grey with no cast since #2062): set apart from the words by the
    /// semibold, never the accent, never the system blue. 6.4:1 on white,
    /// 5.8:1 on the grouped grey; 7.7:1 on the dark card.
    public static let entityInk = dynamic(theme.entityInk)

    // MARK: - Rules (#1169)

    /// How far the accent reaches (#1169, decided 2026-10-14: the UI is
    /// neutral). The defaults are the decision; the DEBUG flags still
    /// compare the two undecided ones on the device.
    public struct Rules: Equatable, Sendable {
        public enum Counters: String, Sendable { case accent, red }
        public enum Ring: String, Sendable { case accent, gradient }

        /// The selected tab in the label's colour, not the accent.
        public var selectedTabIsNeutral = true
        /// The solid unread marks: the primary (decided, #2062), or the
        /// system red to compare.
        public var counters = Counters.accent
        /// The unseen-story ring: the signature gradient, violet → mint
        /// (decided 2026-10-14; the signature itself since #2282), or the
        /// solid accent to compare.
        public var storyRing = Ring.gradient

        public init() {}
    }

    /// The rules the app runs. ⚠️ Written once at launch (`configure`)
    /// before any UI exists; tests read `resolve`, never this.
    nonisolated(unsafe) public static var rules = Rules()

    /// The rule flags a DEBUG launch asks for: `-theme-tab accent|neutral`,
    /// `-theme-counters accent|red`, `-theme-rings accent|gradient`.
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
        return configured
    }

    // MARK: - The loader (#1329)

    /// The loader's gradient (#2147, the owner 2026-11-05): the signature —
    /// violet → mint since #2282, at the loader's own opacities — one layer
    /// across the mark that the pills mask, so the left pill is violet, the
    /// middle sky blue, the right mint. Real alpha: pastel on the light
    /// page, deeper on the dark one. With Increased Contrast, the stops are
    /// opaque and the mint deepened (`signatureContrastStops`). The same in
    /// both appearances otherwise: the mark is a logo, not text.
    public static func loaderGradient(highContrast: Bool) -> [UIColor] {
        guard !highContrast else { return theme.signatureContrastStops.map(rgb) }
        return zip(theme.signatureGradient, theme.loaderOpacities).map { rgb($0).withAlphaComponent($1) }
    }

    /// Where the loader's stops sit: the signature's.
    public static var loaderGradientLocations: [NSNumber] { brandGradientLocations }

    /// The loader's direction, in a layer's unit coordinates: `(0, 0.2) →
    /// (1, 1.03)`, the old icon blob's (#2147), kept as the loader's own.
    public static let loaderGradientStart = CGPoint(x: 0, y: 0.2)
    public static let loaderGradientEnd = CGPoint(x: 1, y: 1.03)

    /// Each pill's lead — its pale wake (#1795): the same gradient, at this
    /// share of the pills' opacity (#2147).
    public static let loaderLeadOpacity: Float = 0.45

    // MARK: - Economy

    /// The saved star (#1128): gold, the 收藏 convention — ONE gold, the
    /// full-screen post's, in both appearances and over media (#1188, #1190:
    /// the owner's reference). Read through `SaveStar`, never directly.
    public static let saveGold = rgb(theme.saveGold)

    /// The same gold — kept as a name for the media surfaces that said so.
    public static var saveGoldOnMedia: UIColor { saveGold }

    /// The Points heart's gradient stops (#1124, decision 7), bottom-left to
    /// top-right: yellow → orange → pink. In the light the yellow start is
    /// the deeper tangerine instead — yellow is 1.51:1 on white, under the
    /// 3:1 a meaningful glyph needs, and it keeps yellow and gold for the
    /// saved star alone. Drawn by the custom heart (#1128), as a mask over a
    /// gradient layer: SF Symbols do not draw a three-stop gradient.
    public static func likesGradient(for traits: UITraitCollection) -> [UIColor] {
        // ⚠️ SOLID: the primary (#1178, the owner 2026-10-15, after a
        // gradient pass). Two equal stops, so the heart's mask and layer —
        // built for a gradient — are untouched. The likes' own role.
        let ink = likesPink.resolvedColor(with: traits)
        return [ink, ink]
    }

    /// The likes' colour: the heart, the likes glyph and coin.
    public static let likesPink = dynamic(theme.likes)

    /// The gems' glyph, the crown (`GemSymbol.tint`, #2071): a bright gold on
    /// light grounds, the owner's pick (2026-11-03) over a deep gold that
    /// read khaki. It is 1.69:1 on white, under a glyph's 3:1, because the
    /// crown always stands beside its amount in `gemText`; Increased
    /// Contrast brings 3:1 back (3.79:1). The brand's yellow on dark
    /// grounds, 13.4:1.
    public static let gem = dynamic(theme.gem)

    /// The gems as TEXT (`GemSymbol.textColor`): a price, a balance, "+N
    /// gems", in the bright gold's hue. 5.38:1 on white, 4.82:1 on the
    /// grouped grey; the yellow in the dark.
    public static let gemText = dynamic(theme.gemText)

    /// The gems' wash (`GemSymbol.ground`): the yellow, at a price bubble's
    /// or a claim's alpha, under `gemText`.
    public static let gemGround = dynamic(theme.gemGround)

    /// THE SIGNATURE GRADIENT (#2282, the owner 2026-11-11): violet
    /// `7235FF` → mint `16FFCB`, through a sky blue, bottom-left to
    /// top-right, interpolated in sRGB. The story ring and the loader wear
    /// it. ⚠️ White text never sits over its mint half (1.30:1); it holds on
    /// the violet end (5.72:1). The violet is never a UI colour on its own.
    public static let brandGradient: [UIColor] = theme.signatureGradient.map(rgb)
    /// Where each of `brandGradient`'s stops sits. Computed: `NSNumber` is
    /// not `Sendable`, so it cannot be a stored static.
    public static var brandGradientLocations: [NSNumber] { theme.signatureLocations.map { NSNumber(value: $0) } }

    /// The unseen-story ring's gradient (#2089): the signature itself since
    /// #2282, along its diagonal (`brandGradientStart` → `brandGradientEnd`),
    /// the same in both appearances. With Increased Contrast, its mint end
    /// deepens to 3:1 on the light page (`signatureContrastStops`), as the
    /// loader's: each stop resolves per contrast setting.
    public static let storyRingGradient: [UIColor] = zip(theme.signatureGradient, theme.signatureContrastStops)
        .map { stop, contrastStop in dynamic(light: stop, dark: stop, lightIC: contrastStop, darkIC: contrastStop) }
    /// Where each of `storyRingGradient`'s stops sits: the signature's.
    public static var storyRingGradientLocations: [NSNumber] { brandGradientLocations }

    /// Where `brandGradient` (and the story ring's) runs, in a layer's unit
    /// space.
    public static let brandGradientStart = CGPoint(x: 0, y: 1)
    public static let brandGradientEnd = CGPoint(x: 1, y: 0)

    // MARK: - Avatar frames (#943)

    /// The avatar frames' rings, swept around the face from twelve o'clock
    /// (`AvatarFrame`) — the economy's cosmetics, not the theme: a frame is
    /// the same object for everyone who sees it (`BrandCosmetics`). v1 art,
    /// drawn in code (no designer yet), to tune on device.
    public static let frameGold: [UIColor] = BrandCosmetics.frameGold.map(rgb)
    public static let frameNeon: [UIColor] = BrandCosmetics.frameNeon.map(rgb)
    public static let frameNeonGlow = rgb(BrandCosmetics.frameNeonGlow)
    public static let frameAurora: [UIColor] = BrandCosmetics.frameAurora.map(rgb)

    // MARK: - Building

    /// The theme every role derives from.
    static var theme: BrandTheme { BrandTheme.current }

    /// One role's shade as an appearance- and contrast-dynamic colour.
    static func dynamic(_ shade: BrandTheme.Shade) -> UIColor {
        dynamic(light: shade.light, dark: shade.dark, lightIC: shade.lightIC, darkIC: shade.darkIC)
    }

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
