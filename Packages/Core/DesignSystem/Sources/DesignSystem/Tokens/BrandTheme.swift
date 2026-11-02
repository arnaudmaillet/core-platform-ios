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

    /// Every solid unread mark: badges, the bell's dot, counts.
    public let counter: Shade
    /// The gradient a few marks wear (the unseen-story ring, the inbox's
    /// unread pills), first stop to last.
    public let accentGradient: [UInt32]

    // MARK: - Secondary

    public let secondary: Shade
    public let secondaryContainer: Shade
    public let onSecondaryContainer: Shade

    // MARK: - Text

    /// `@mentions`, `#hashtags` and links.
    public let entityInk: Shade

    // MARK: - The economy

    /// The likes' heart, glyph and coin.
    public let likes: Shade
    /// The gems.
    public let gem: Shade
    /// The saved star: one gold.
    public let saveGold: UInt32

    // MARK: - Brand moments

    /// The brand's signature gradient, first stop to last (splash, the
    /// Shop's hero art, the wallet's hero rule, the profile switcher's
    /// counts).
    public let signatureGradient: [UInt32]
    /// The branded loader's three pills, left to right.
    public let loaderTones: [UInt32]

    // MARK: - The assets (checked by `BrandAssetsGuardTests`)

    /// `LaunchLogo.svg`'s gradient stops, first to last.
    public let launchLogoStops: [UInt32]
    /// `AppIcon.icon/icon.json`'s blob fill, exactly as Icon Composer writes
    /// it, first stop to last.
    public let iconGradient: [String]

    /// The theme the app draws in.
    public static let current = pink

    /// Pink (#1169, #1190): the palette before #2062's raspberry.
    public static let pink = BrandTheme(
        name: "pink",
        primary: Shade(0xF37AB4, 0xF37AB4, ic: (0xB0256A, 0xF8ABCF)),
        primarySolid: Shade(0xF37AB4, 0xF37AB4),
        onPrimary: Shade(0xFFFFFF, 0x2B0716),
        primaryPressed: Shade(0xE86AA6, 0xE86AA6, ic: (0x9C1F5E, 0xE86AA6)),
        primaryContainer: Shade(0xFDE3EF, 0x3A0A22),
        onPrimaryContainer: Shade(0xB8296C, 0xF8ABCF),
        counter: Shade(0x7C5CF0, 0x7C5CF0),
        accentGradient: [0xF37AB4, 0xA78BFA],
        secondary: Shade(0x6852C6, 0xA78BFA, ic: (0x5C44B7, 0xB59EFF)),
        secondaryContainer: Shade(0xEFEEFF, 0x211944),
        onSecondaryContainer: Shade(0x6852C6, 0xA78BFA),
        entityInk: Shade(0x645A82, 0xAFA3CC, ic: (0x4F4669, 0xC3B9DD)),
        likes: Shade(0xF37AB4, 0xF37AB4, ic: (0xB0256A, 0xF8ABCF)),
        gem: Shade(0x6852C6, 0xA78BFA, ic: (0x5C44B7, 0xB59EFF)),
        saveGold: 0xFFC53D,
        signatureGradient: [0xE0559A, 0x7C5CF0],
        loaderTones: [0xF37AB4, 0xD98AD0, 0xA78BFA],
        launchLogoStops: [0xEDAACB, 0xD0CCFC],
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
