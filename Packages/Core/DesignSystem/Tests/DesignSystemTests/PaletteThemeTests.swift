import Testing
import UIKit
@testable import DesignSystem

/// The theme (#2062, raspberry): every role resolves in light, dark and
/// Increased Contrast and holds the contrast its use needs — and a launch
/// with no flag runs the decided neutral-first rules.
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

    private static let roles: [(String, UIColor)] = [
        ("tint", Palette.tint), ("brandText", Palette.brandText), ("primaryFill", Palette.primaryFill),
        ("onPrimary", Palette.onPrimary), ("primaryFillPressed", Palette.primaryFillPressed),
        ("prominentGlassTint", Palette.prominentGlassTint), ("primaryContainer", Palette.primaryContainer),
        ("onPrimaryContainer", Palette.onPrimaryContainer),
    ]

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

    /// The owner's value, exactly: base 500 in both appearances (#2062).
    @Test func theAccentIsTheChosenRaspberry() {
        let light = Palette.tint.resolvedColor(with: Self.traits[0])
        let dark = Palette.tint.resolvedColor(with: Self.traits[1])
        #expect(light == Palette.rgb(BrandTheme.current.primary.light))
        #expect(dark == Palette.rgb(BrandTheme.current.primary.dark))
        #expect(BrandTheme.current.primary.light == 0xEC1C75)
    }

    /// Every role, every appearance, opaque.
    @Test func everyRoleResolves() {
        for (role, colour) in Self.roles {
            for traits in Self.traits {
                var alpha: CGFloat = 0
                colour.resolvedColor(with: traits).getRed(nil, green: nil, blue: nil, alpha: &alpha)
                #expect(alpha == 1, "\(role) is not opaque in \(traits)")
            }
        }
    }

    /// The raspberry reads at 4.2:1 on white and on black — the owner's base
    /// 500 — and Increased Contrast takes it past 4.5:1 on either, never
    /// lower; a filled button's white label reads at 4.2:1, and 4.5:1 under
    /// Increased Contrast.
    @Test func theAccentReads() {
        let (light, dark, lightIC, darkIC) = (Self.traits[0], Self.traits[1], Self.traits[2], Self.traits[3])
        let tintLight = Self.contrast(Palette.tint.resolvedColor(with: light), .white)
        let tintDark = Self.contrast(Palette.tint.resolvedColor(with: dark), .black)
        #expect(tintLight >= 4.2, "tint \(tintLight):1 on white")
        #expect(tintDark >= 4.5, "tint \(tintDark):1 on black")
        #expect(Self.contrast(Palette.tint.resolvedColor(with: lightIC), .white) >= 4.5)
        #expect(Self.contrast(Palette.tint.resolvedColor(with: darkIC), .black) >= 4.5)
        #expect(Self.contrast(Palette.tint.resolvedColor(with: lightIC), .white) >= tintLight)
        #expect(Self.contrast(Palette.tint.resolvedColor(with: darkIC), .black) >= tintDark)
        for traits in [light, dark] {
            let onFill = Self.contrast(Palette.onPrimary.resolvedColor(with: traits), Palette.primaryFill.resolvedColor(with: traits))
            #expect(onFill >= 4.2, "onPrimary \(onFill):1")
        }
        for traits in [lightIC, darkIC] {
            let onFill = Self.contrast(Palette.onPrimary.resolvedColor(with: traits), Palette.primaryFill.resolvedColor(with: traits))
            #expect(onFill >= 4.5, "onPrimary \(onFill):1 under Increased Contrast")
        }
    }

    /// The signature gradient (#2062): raspberry at 0, violet at 0.5, mint at
    /// 1, bottom-left to top-right. ⚠️ No white text over it: its mint half
    /// is 1.5:1 under white.
    @Test func theSignatureRunsRaspberryVioletMint() {
        #expect(Palette.brandGradient == BrandTheme.current.signatureGradient.map(Palette.rgb))
        #expect(Palette.brandGradientLocations == [0, 0.5, 1])
        #expect(Self.contrast(.white, Palette.brandGradient[2]) < 2, "the mint carries no white words")
        #expect(Palette.brandGradientStart == CGPoint(x: 0, y: 1), "it starts at the bottom-left, as the icon")
    }

    @Test func aLaunchWithNoFlagRunsTheDecidedRules() {
        let rules = Palette.resolve(arguments: [])
        #expect(rules == Palette.Rules())
        #expect(rules.selectedTabIsNeutral)
        #expect(rules.counters == .accent, "unread marks are the raspberry (#2062)")
        let mark = Palette.counterMark.resolvedColor(with: Self.traits[0])
        #expect(Self.contrast(.white, mark) >= 4.2, "a white count on the mark")
        #expect(rules.storyRing == .gradient, "the ring wears the signature gradient (decided)")
    }

    @Test func theFlagsPickTheRules() {
        let rules = Palette.resolve(arguments: [
            "-theme-tab", "accent", "-theme-counters", "red", "-theme-rings", "accent",
        ])
        #expect(!rules.selectedTabIsNeutral)
        #expect(rules.counters == .red)
        #expect(rules.storyRing == .accent)
        #expect(Palette.resolve(arguments: ["-theme-counters", "violet"]).counters == .accent, "the violet case is gone")
    }
}
