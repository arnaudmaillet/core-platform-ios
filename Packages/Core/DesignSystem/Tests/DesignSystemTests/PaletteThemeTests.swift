import Testing
import UIKit
@testable import DesignSystem

/// The accent as a theme (#1169): five candidates to compare on the device,
/// each resolving every role in light, dark and Increased Contrast, each held
/// to the contrast its roles need — and a launch that asks for none runs the
/// shipped one with the decided rules.
@MainActor
struct PaletteThemeTests {
    private static let traits: [UITraitCollection] = [
        (UIUserInterfaceStyle.light, UIAccessibilityContrast.normal),
        (.dark, .normal), (.light, .high), (.dark, .high),
    ].map { style, contrast in
        UITraitCollection(mutations: {
            $0.userInterfaceStyle = style
            $0.accessibilityContrast = contrast
        })
    }

    private static func roles(_ theme: Palette.Theme) -> [(String, UIColor)] {
        [
            ("tint", theme.tint), ("brandText", theme.brandText), ("primaryFill", theme.primaryFill),
            ("onPrimary", theme.onPrimary), ("primaryFillPressed", theme.primaryFillPressed),
            ("prominentGlassTint", theme.prominentGlassTint), ("primaryContainer", theme.primaryContainer),
            ("onPrimaryContainer", theme.onPrimaryContainer),
        ]
    }

    /// WCAG relative luminance contrast.
    private static func contrast(_ a: UIColor, _ b: UIColor) -> CGFloat {
        func luminance(_ colour: UIColor) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
            colour.getRed(&r, green: &g, blue: &b, alpha: &alpha)
            func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }

    @Test func everyThemeIsNamedOnce() {
        #expect(Palette.themes.map(\.name) == ["current", "flame", "raspberry", "pink", "orchid"])
        #expect(Palette.shipped.name == "current")
    }

    /// Every role, every appearance, opaque.
    @Test(arguments: Palette.themes.map(\.name))
    func everyRoleResolves(_ name: String) throws {
        let theme = try #require(Palette.themes.first { $0.name == name })
        for (role, colour) in Self.roles(theme) {
            for traits in Self.traits {
                var alpha: CGFloat = 0
                colour.resolvedColor(with: traits).getRed(nil, green: nil, blue: nil, alpha: &alpha)
                #expect(alpha == 1, "\(name).\(role) is not opaque in \(traits)")
            }
        }
    }

    /// The tint is held to a control's 3:1 on white (light) and black
    /// (dark); text in the accent to 4.5:1; Increased Contrast never lowers
    /// either.
    @Test(arguments: Palette.themes.map(\.name))
    func theAccentReads(_ name: String) throws {
        let theme = try #require(Palette.themes.first { $0.name == name })
        let (light, dark, lightIC, darkIC) = (Self.traits[0], Self.traits[1], Self.traits[2], Self.traits[3])
        let tintLight = Self.contrast(theme.tint.resolvedColor(with: light), .white)
        let tintDark = Self.contrast(theme.tint.resolvedColor(with: dark), .black)
        #expect(tintLight >= 3, "\(name) tint \(tintLight):1 on white")
        #expect(tintDark >= 3, "\(name) tint \(tintDark):1 on black")
        #expect(Self.contrast(theme.brandText.resolvedColor(with: light), .white) >= 4.5, "\(name) brandText on white")
        #expect(Self.contrast(theme.brandText.resolvedColor(with: dark), .black) >= 4.5, "\(name) brandText on black")
        #expect(Self.contrast(theme.tint.resolvedColor(with: lightIC), .white) >= tintLight)
        #expect(Self.contrast(theme.tint.resolvedColor(with: darkIC), .black) >= tintDark)
        // The label on a filled button: 4.5:1 in the light — a large bold
        // label's 3:1 for the bright pink.
        let onFill = Self.contrast(theme.onPrimary.resolvedColor(with: light), theme.primaryFill.resolvedColor(with: light))
        #expect(onFill >= (name == "pink" || name == "flame" ? 3 : 4.5), "\(name) onPrimary \(onFill):1")
    }

    @Test func aLaunchWithNoFlagRunsTheShippedThemeAndTheDecidedRules() {
        let resolved = Palette.resolve(arguments: [])
        #expect(resolved.theme.name == "current")
        #expect(resolved.rules == Palette.Rules())
        #expect(resolved.rules.selectedTabIsNeutral)
        #expect(resolved.rules.counters == .accent)
        #expect(resolved.rules.storyRing == .accent)
        #expect(resolved.rules.heroButton == .accent)
    }

    @Test func theFlagsPickAThemeAndItsRules() {
        let resolved = Palette.resolve(arguments: [
            "-theme", "pink", "-theme-tab", "accent", "-theme-counters", "red",
            "-theme-rings", "gradient", "-theme-hero", "gradient",
        ])
        #expect(resolved.theme.name == "pink")
        #expect(!resolved.rules.selectedTabIsNeutral)
        #expect(resolved.rules.counters == .red)
        #expect(resolved.rules.storyRing == .gradient)
        #expect(resolved.rules.heroButton == .gradient)
        #expect(Palette.resolve(arguments: ["-theme", "teal"]).theme.name == "current", "an unknown name is ignored")
    }
}
