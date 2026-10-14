import Testing
import UIKit
@testable import DesignSystem

/// The brand palette (#1124): every role legible where it is used, in both
/// appearances, and Increased Contrast resolving to its own values.
@MainActor
struct PaletteTests {
    private static let light = UITraitCollection(userInterfaceStyle: .light)
    private static let dark = UITraitCollection(userInterfaceStyle: .dark)

    private static func traits(_ style: UIUserInterfaceStyle, high: Bool = false) -> UITraitCollection {
        UITraitCollection(mutations: {
            $0.userInterfaceStyle = style
            $0.accessibilityContrast = high ? .high : .normal
        })
    }

    /// WCAG 2.x relative luminance.
    private static func luminance(_ color: UIColor, _ traits: UITraitCollection) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ c: CGFloat) -> CGFloat {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    private static func contrast(_ a: UIColor, on b: UIColor, _ traits: UITraitCollection) -> CGFloat {
        let la = luminance(a, traits), lb = luminance(b, traits)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func hex(_ color: UIColor, _ traits: UITraitCollection) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return UInt32((r * 255).rounded()) << 16 | UInt32((g * 255).rounded()) << 8 | UInt32((b * 255).rounded())
    }

    /// Glyph and control roles: 3:1 (WCAG 1.4.11) on the page and on the
    /// raised ground, in both appearances.
    @Test(arguments: [
        ("tint", Palette.tint), ("secondary", Palette.secondary), ("saveGold", Palette.saveGold),
    ])
    func aGlyphRoleReadsOnEveryGround(_ role: (String, UIColor)) {
        for traits in [Self.light, Self.dark] {
            for ground in [UIColor.systemBackground, .secondarySystemBackground] {
                let ratio = Self.contrast(role.1, on: ground, traits)
                #expect(ratio >= 3, "\(role.0) is \(ratio):1 in \(traits.userInterfaceStyle == .dark ? "dark" : "light")")
            }
        }
    }

    /// Text roles: 4.5:1 on the grounds body text lies on — the page and a
    /// card — in both appearances.
    @Test(arguments: [("brandText", Palette.brandText), ("secondary", Palette.secondary)])
    func aTextRoleReadsAsText(_ role: (String, UIColor)) {
        for traits in [Self.light, Self.dark] {
            for ground in [UIColor.systemBackground, .secondarySystemGroupedBackground] {
                let ratio = Self.contrast(role.1, on: ground, traits)
                #expect(ratio >= 4.5, "\(role.0) is \(ratio):1 in \(traits.userInterfaceStyle == .dark ? "dark" : "light")")
            }
        }
    }

    /// The text that sits on a brand ground: 4.5:1 on it.
    @Test func theLabelsOnBrandGroundsReadAsText() {
        let pairs: [(String, UIColor, UIColor)] = [
            ("onPrimary", Palette.onPrimary, Palette.primaryFill),
            ("onPrimary pressed", Palette.onPrimary, Palette.primaryFillPressed),
            ("onPrimaryContainer", Palette.onPrimaryContainer, Palette.primaryContainer),
            ("onSecondaryContainer", Palette.onSecondaryContainer, Palette.secondaryContainer),
        ]
        for (name, text, ground) in pairs {
            for traits in [Self.light, Self.dark] {
                let ratio = Self.contrast(text, on: ground, traits)
                #expect(ratio >= 4.5, "\(name) is \(ratio):1")
            }
        }
    }

    /// ⚠️ A white label on the vivid fill fails, which is why `onPrimary` is
    /// a dark ink: pinned, so nobody "fixes" the ink to white.
    @Test func whiteOnTheVividFillFails() {
        #expect(Self.contrast(.white, on: Palette.primaryFill, Self.light) < 3)
    }

    /// Increased Contrast resolves to the IC values.
    @Test func increasedContrastResolvesToItsOwnValues() {
        #expect(Self.hex(Palette.tint, Self.traits(.light)) == 0xC76300)
        #expect(Self.hex(Palette.tint, Self.traits(.dark)) == 0xFFAD66)
        #expect(Self.hex(Palette.tint, Self.traits(.light, high: true)) == 0x8B4600)
        #expect(Self.hex(Palette.tint, Self.traits(.dark, high: true)) == 0xFFD0AA)
        #expect(Self.hex(Palette.secondary, Self.traits(.light, high: true)) == 0x5C44B7)
        #expect(Self.hex(Palette.secondary, Self.traits(.dark, high: true)) == 0xB59EFF)
        // A role without IC values keeps its ordinary one.
        #expect(Self.hex(Palette.primaryFill, Self.traits(.light, high: true)) == 0xFF8D28)
    }

    /// The heart's gradient: three stops, and the light one starts on the
    /// deeper tangerine (3:1 on white), never yellow — yellow is the saved
    /// star's.
    @Test func thePointsGradientStartsDeepInTheLight() {
        let light = PointsSymbol.gradient(for: Self.light)
        let dark = PointsSymbol.gradient(for: Self.dark)
        #expect(light.count == 3 && dark.count == 3)
        #expect(Self.hex(light[0], Self.light) == 0xC76300)
        #expect(Self.contrast(light[0], on: .white, Self.light) >= 3)
    }
}
