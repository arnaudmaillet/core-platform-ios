import Testing
import UIKit
@testable import DesignSystem

/// The accent (#1169, pink, chosen 2026-10-14): every role resolves in light,
/// dark and Increased Contrast and holds the contrast its use needs — and a
/// launch with no flag runs the decided neutral-first rules.
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

    /// The owner's two values, exactly.
    @Test func theAccentIsTheChosenPink() {
        let light = Palette.tint.resolvedColor(with: Self.traits[0])
        let dark = Palette.tint.resolvedColor(with: Self.traits[1])
        #expect(light == Palette.rgb(0xD6337F))
        #expect(dark == Palette.rgb(0xF37AB4))
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

    /// Text in the accent reads (4.5:1) on white and black, Increased
    /// Contrast never lowers it, and a filled button's label passes.
    @Test func theAccentReads() {
        let (light, dark, lightIC, darkIC) = (Self.traits[0], Self.traits[1], Self.traits[2], Self.traits[3])
        let tintLight = Self.contrast(Palette.tint.resolvedColor(with: light), .white)
        let tintDark = Self.contrast(Palette.tint.resolvedColor(with: dark), .black)
        #expect(tintLight >= 4.5, "tint \(tintLight):1 on white")
        #expect(tintDark >= 4.5, "tint \(tintDark):1 on black")
        #expect(Self.contrast(Palette.brandText.resolvedColor(with: light), .white) >= 4.5)
        #expect(Self.contrast(Palette.brandText.resolvedColor(with: dark), .black) >= 4.5)
        #expect(Self.contrast(Palette.tint.resolvedColor(with: lightIC), .white) >= tintLight)
        #expect(Self.contrast(Palette.tint.resolvedColor(with: darkIC), .black) >= tintDark)
        for traits in [light, dark] {
            let onFill = Self.contrast(
                Palette.onPrimary.resolvedColor(with: traits), Palette.primaryFill.resolvedColor(with: traits)
            )
            #expect(onFill >= 4.5, "onPrimary \(onFill):1 in \(traits.userInterfaceStyle.rawValue)")
        }
        #expect(Self.contrast(.white, Palette.prominentGlassTint) >= 4.5, "the glass's white label")
    }

    /// The icon's gradient on the unread pills and the story ring: pink →
    /// violet since the icon was redrawn (#1176), in the icon's tone — the
    /// owner's call over 3:1. A white count still stands out (≥ 1.8:1).
    @Test func theAccentGradientRunsPinkToVioletInTheIconsTone() {
        #expect(Palette.accentGradient == [Palette.rgb(0xF37AB4), Palette.rgb(0xA78BFA)])
        #expect(Palette.brandGradient == [Palette.rgb(0xE0559A), Palette.rgb(0x7C5CF0)])
        for gradient in [Palette.accentGradient, Palette.brandGradient] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            gradient[0].getRed(&r, green: &g, blue: &b, alpha: &a)
            #expect(r > b, "the start is pink")
            gradient[1].getRed(&r, green: &g, blue: &b, alpha: &a)
            #expect(b > r, "the end is violet")
        }
        for stop in Palette.accentGradient {
            #expect(Self.contrast(.white, stop) >= 1.8, "white on a stop is \(Self.contrast(.white, stop)):1")
        }
        #expect(Palette.accentGradientStart == CGPoint(x: 0, y: 1), "pink starts at the bottom-left, as the icon")
    }

    @Test func aLaunchWithNoFlagRunsTheDecidedRules() {
        let rules = Palette.resolve(arguments: [])
        #expect(rules == Palette.Rules())
        #expect(rules.selectedTabIsNeutral)
        #expect(rules.counters == .violet, "unread marks are the violet (decided, #1178)")
        #expect(Palette.rgb(0x7C5CF0) == Palette.counterViolet)
        #expect(Self.contrast(.white, Palette.counterViolet) >= 4.5, "a white count on the violet")
        #expect(rules.storyRing == .gradient, "the ring wears the icon's gradient (decided)")
        #expect(rules.heroButton == .accent)
    }

    @Test func theFlagsPickTheRules() {
        let rules = Palette.resolve(arguments: [
            "-theme-tab", "accent", "-theme-counters", "accent", "-theme-rings", "accent", "-theme-hero", "gradient",
        ])
        #expect(!rules.selectedTabIsNeutral)
        #expect(rules.counters == .accent)
        #expect(rules.storyRing == .accent)
        #expect(rules.heroButton == .gradient)
    }
}
