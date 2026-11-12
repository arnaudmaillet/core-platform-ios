import Foundation

/// THE BRAND'S RAW COLOURS, IN ONE PLACE (#2062). Every hex the app draws
/// its brand in is here and nowhere else: `Palette`'s roles derive from
/// `BrandTheme.current`, and the assets that hold a colour outside the code
/// (`AccentColor`, the launch picture, the app icon) are checked by
/// `BrandAssetsGuardTests`.
///
/// **Changing the theme** (`dev/BRAND_PALETTE.md`, "Changing the theme"):
/// write a new `BrandTheme` value, point `current` at it, update the assets
/// until the guard passes, redo the icon, check the contrast table. No call
/// site changes: they read `Palette`'s roles.
///
/// One theme only (the owner, 2026-11-02): the Shop's paid accent themes
/// (#1379) are retired. If they come back, a theme is a second value here and
/// a trait that picks one.
///
/// `RawHueGuardTests` keeps hex literals out of every other Swift file.
public struct BrandTheme: Sendable, Equatable {
    /// One role's values: light, dark, and the Increased Contrast pair (the
    /// ordinary ones without it). sRGB hex.
    public struct Shade: Sendable, Equatable {
        public let light: UInt32
        public let dark: UInt32
        public let lightIC: UInt32
        public let darkIC: UInt32

        public init(_ light: UInt32, _ dark: UInt32, ic: (light: UInt32, dark: UInt32)? = nil) {
            self.light = light
            self.dark = dark
            self.lightIC = ic?.light ?? light
            self.darkIC = ic?.dark ?? dark
        }
    }

    /// The name, for the doc and the logs.
    public let name: String

    // MARK: - The primary

    /// The app's tint and glyphs, with its Increased Contrast pair (deeper
    /// in the light, lifted in the dark). `AccentColor` carries these four
    /// values.
    public let primary: Shade
    /// The primary as TEXT (#2282): a "See all", a text button. Deeper than
    /// `primary` in the light only, where the primary itself is under 4.5:1
    /// on white; the same hue. Increased Contrast deepens it further in the
    /// light and lifts it in the dark, as `primary`.
    public let primaryText: Shade
    /// The primary filled button's ground: the primary, deepened under
    /// Increased Contrast in BOTH appearances, so its white label reads —
    /// the tint's lifted dark IC value would carry it under 3:1.
    public let primaryFill: Shade
    /// The same colour as a solid ground with no contrast step: the
    /// prominent fill and the prominent glass's tint.
    public let primarySolid: Shade
    /// The label on the primary fill.
    public let onPrimary: Shade
    /// The primary fill pressed.
    public let primaryPressed: Shade
    /// A soft selected ground, and its text.
    public let primaryContainer: Shade
    public let onPrimaryContainer: Shade

    // MARK: - The accent (the mint, #2282)

    /// The brand's second colour, as a GLYPH: the mint on dark grounds, a
    /// deep mint on light ones, where the mint itself is 1.16:1 on the
    /// page. ⚠️ Not a UI colour by default (the owner, #2282 § 3): no
    /// `Palette` role reads it. It is the signature gradient's end, and the
    /// icon's echo; a place that wants it is a follow-up the owner names.
    public let accent: Shade
    /// The mint as TEXT: a deeper mint in the light, for 4.5:1 on white.
    /// Never white text on the mint (1.30:1). Not a UI colour by default
    /// either.
    public let accentText: Shade

    // MARK: - Marks

    /// Every unread mark, pill and badge: solid, never a gradient (the
    /// owner, 2026-11-02), under a white count.
    public let counter: Shade

    // MARK: - Text

    /// `@mentions`, `#hashtags` and links: a grey with no cast, set apart
    /// by the semibold.
    public let entityInk: Shade

    // MARK: - The economy

    /// The likes' heart, glyph and coin.
    public let likes: Shade
    /// The gems' glyph, the crown (#2071): the brand's yellow on dark
    /// grounds, a bright gold on light ones (the owner's pick, 2026-11-03),
    /// with a deeper gold under Increased Contrast.
    public let gem: Shade
    /// The gems as TEXT — a price, a balance, "+N": a deeper gold in the
    /// light, for 4.5:1 where the glyph's 3:1 is not.
    public let gemText: Shade
    /// The gems' wash under a price or a claim, at the bubble's alpha: the
    /// yellow itself in both appearances, under `gemText`.
    public let gemGround: Shade
    /// The saved star: one gold, apart from the crowns' yellow.
    public let saveGold: UInt32

    // MARK: - Brand moments

    /// The brand's signature gradient, first stop to last, and where each
    /// stop sits (0…1), interpolated in sRGB: the violet to the mint
    /// (#2282, the owner 2026-11-11), without the primary — a gradient from
    /// the primary to the mint goes grey in the middle. The unseen-story
    /// ring (#2089) wears it; the loader left it (#2340). ⚠️ The violet
    /// appears only inside it, never as a UI colour on its own.
    public let signatureGradient: [UInt32]
    public let signatureLocations: [Double]
    /// The signature with Increased Contrast, for the ring: opaque, its
    /// mint end deepened to reach 3:1 on the light page (`F2F2F7`) — the
    /// mint itself is 1.16:1 there. The crown's precedent (#2071), as #2147
    /// did.
    public let signatureContrastStops: [UInt32]
    /// The loader's three pills, left to right (#2340, the owner
    /// 2026-11-12): the primary, then the same hue less saturated at each
    /// step (HSB S 0.93 → 0.65 → 0.42, B 1), so the three read as one
    /// gradient and never as a disabled grey. Opaque, the same in both
    /// appearances: the mark is a logo, not text. With Increased Contrast
    /// all three take the primary's own IC value (`primary.lightIC`,
    /// `primary.darkIC`). It replaced the signature masked by the pills
    /// (#2147, #2282).
    public let loaderSteps: [UInt32]

    /// The theme the app draws in.
    public static let current = coral

    /// Coral (#2282, the owner 2026-11-11): the primary `FF1358` almost
    /// everywhere, a deeper shade of it for text in the light, the yellow
    /// for the gems' crown (#2071), and the signature running violet → mint.
    /// It replaced the raspberry `EC1C75` (#2062).
    public static let coral = BrandTheme(
        name: "coral",
        primary: Shade(0xFF1358, 0xFF1358, ic: (0xC6003A, 0xFF5C8C)),
        primaryText: Shade(0xEB0045, 0xFF1358, ic: (0xC6003A, 0xFF5C8C)),
        primaryFill: Shade(0xFF1358, 0xFF1358, ic: (0xC6003A, 0xC6003A)),
        primarySolid: Shade(0xFF1358, 0xFF1358),
        onPrimary: Shade(0xFFFFFF, 0xFFFFFF),
        primaryPressed: Shade(0xDA0040, 0xDA0040, ic: (0xAA0032, 0xDA0040)),
        primaryContainer: Shade(0xFFE3EB, 0x3D0515),
        onPrimaryContainer: Shade(0xB20034, 0xFF7DA3),
        accent: Shade(0x009E7B, 0x16FFCB, ic: (0x008567, 0x16FFCB)),
        accentText: Shade(0x008567, 0x16FFCB, ic: (0x007157, 0x16FFCB)),
        counter: Shade(0xFF1358, 0xFF1358, ic: (0xC6003A, 0xC6003A)),
        entityInk: Shade(0x5E5E66, 0xAEAEB4, ic: (0x48484F, 0xC8C8CD)),
        likes: Shade(0xFF1358, 0xFF1358, ic: (0xC6003A, 0xFF5C8C)),
        gem: Shade(0xF5C000, 0xFFE600, ic: (0xA87C00, 0xFFE600)),
        gemText: Shade(0x8A6400, 0xFFE600, ic: (0x7A5800, 0xFFE600)),
        gemGround: Shade(0xFFE600, 0xFFE600),
        saveGold: 0xFFC53D,
        signatureGradient: [0x7235FF, 0x16FFCB],
        signatureLocations: [0, 1],
        signatureContrastStops: [0x7235FF, 0x009E7B],
        loaderSteps: [0xFF1358, 0xFF598A, 0xFF94B3]
    )
}

extension BrandTheme {
    /// The keys the retired accent themes (#1379) stored: the theme each
    /// account chose on this device, and the last one applied.
    static let retiredThemeKeys = ["display.accentTheme", "display.accentTheme.lastApplied"]

    /// Forgets the retired accent theme a device stored (#2062): read by
    /// nothing any more, so a device that applied violet opens in the one
    /// theme either way — this only leaves no dead value behind. Each
    /// launch, as `LowPowerMode.forgetPowerSaving`: removing a missing key
    /// costs nothing.
    public static func forgetRetiredThemes(in defaults: UserDefaults = .standard) {
        for key in retiredThemeKeys { defaults.removeObject(forKey: key) }
    }
}

/// The raw neutrals the palette mixes with — not the brand, but hex all the
/// same, so they live beside it (`RawHueGuardTests`).
public enum BrandNeutrals {
    /// The grouped page's light grey (`systemGroupedBackground` in the
    /// light), where the brand's contrast is measured.
    public static let pageLight: UInt32 = 0xF2F2F7
}

/// The avatar frames' sweeps (#943): COSMETICS, not the theme — the same
/// object for everyone who sees it, whatever the brand. Here only because
/// they are hex (`RawHueGuardTests`); a theme change leaves them alone.
public enum BrandCosmetics {
    /// Gold: a warm metal, light catching at the top and the bottom-right.
    public static let frameGold: [UInt32] = [0xFFE9A8, 0xE2B14A, 0xA87412, 0xF5D27A, 0xC8901E, 0xFFE9A8]
    /// Neon: cyan and violet, with a glow of the cyan.
    public static let frameNeon: [UInt32] = [0x22D3EE, 0xA855F7, 0x22D3EE, 0xA855F7, 0x22D3EE]
    public static let frameNeonGlow: UInt32 = 0x22D3EE
    /// Aurora: green into cyan, violet and pink, and round again.
    public static let frameAurora: [UInt32] = [0x34D399, 0x22D3EE, 0xA78BFA, 0xF472B6, 0x34D399]
}
