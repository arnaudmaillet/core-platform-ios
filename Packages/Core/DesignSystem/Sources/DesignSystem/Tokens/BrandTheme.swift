import Foundation

/// THE BRAND'S RAW COLOURS, IN ONE PLACE (#2062). Every hex the app draws
/// its brand in is here and nowhere else: `Palette`'s roles derive from
/// `BrandTheme.current`, and the assets that hold a colour outside the code
/// (`AccentColor`, the launch logo, the app icon) are checked against it by
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

    /// The app's tint, the accent's text, the primary fill — with its
    /// Increased Contrast pair. `AccentColor` carries these four values.
    public let primary: Shade
    /// The primary filled button's ground: the primary, deepened under
    /// Increased Contrast in BOTH appearances, so its white label reads —
    /// the tint's lifted dark IC value would carry it at 3.1:1.
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
    /// The gems' glyph. The violet is the gems' alone, outside the signature
    /// gradient.
    public let gem: Shade
    /// The gems' violet as TEXT — a price, a balance: deep enough for
    /// 4.5:1 where the glyph's 3:1 is not.
    public let gemText: Shade
    /// The saved star: one gold.
    public let saveGold: UInt32
    /// Recorded, not drawn: the crowns' colour, when the crowns replace the
    /// gems. It becomes a role only then.
    public let crownYellow: UInt32

    // MARK: - Brand moments

    /// The brand's signature gradient, first stop to last, and where each
    /// stop sits (0…1): the launch logo, the story ring.
    public let signatureGradient: [UInt32]
    public let signatureLocations: [Double]
    /// The branded loader's three pills, left to right.
    public let loaderTones: [UInt32]

    // MARK: - The assets (checked by `BrandAssetsGuardTests`)

    /// `LaunchLogo.svg`'s gradient stops, first to last: the signature's,
    /// made pale.
    public let launchLogoStops: [UInt32]
    /// `AppIcon.icon/icon.json`'s blob fill, exactly as Icon Composer writes
    /// it, first stop to last.
    public let iconGradient: [String]

    /// The theme the app draws in.
    public static let current = raspberry

    /// Raspberry (#2062, the owner 2026-11-02): the primary almost
    /// everywhere, the violet for the gems, the signature running raspberry →
    /// violet → mint.
    public static let raspberry = BrandTheme(
        name: "raspberry",
        primary: Shade(0xEC1C75, 0xEC1C75, ic: (0xC2105F, 0xF25C9A)),
        primaryFill: Shade(0xEC1C75, 0xEC1C75, ic: (0xC2105F, 0xC2105F)),
        primarySolid: Shade(0xEC1C75, 0xEC1C75),
        onPrimary: Shade(0xFFFFFF, 0xFFFFFF),
        primaryPressed: Shade(0xD41868, 0xD41868, ic: (0xA80D52, 0xD41868)),
        primaryContainer: Shade(0xFDE3EE, 0x3D0A20),
        onPrimaryContainer: Shade(0xB00E57, 0xF57BAE),
        counter: Shade(0xEC1C75, 0xEC1C75, ic: (0xC2105F, 0xC2105F)),
        entityInk: Shade(0x5E5E66, 0xAEAEB4, ic: (0x48484F, 0xC8C8CD)),
        likes: Shade(0xEC1C75, 0xEC1C75, ic: (0xC2105F, 0xF25C9A)),
        gem: Shade(0x9B5CFF, 0x9B5CFF, ic: (0x7A3FE0, 0xB48AFF)),
        gemText: Shade(0x7A3FE0, 0xA97AFF, ic: (0x6E33D6, 0xB48AFF)),
        saveGold: 0xFFC53D,
        crownYellow: 0xFFE600,
        signatureGradient: [0xEC1C75, 0x9B5CFF, 0x2EF0A8],
        signatureLocations: [0, 0.5, 1],
        loaderTones: [0xEC1C75, 0x9B5CFF, 0x2EF0A8],
        launchLogoStops: [0xF699C1, 0xD2B6FF, 0xA1F8D8],
        // The icon is redone in #2062's third pull request: until then, its
        // fill as it stands.
        iconGradient: [
            "display-p3:0.85622,0.33380,0.59312,0.50000",
            "extended-srgb:0.38039,0.33333,0.96078,0.30000",
        ]
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
    /// light), which the loader's leads are mixed toward.
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
