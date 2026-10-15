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
    /// raised ground, in both appearances. ⚠️ The light pink and the save gold
    /// are lighter than that BY CHOICE (#1190, the owner, 2026-10-15): the
    /// pink holds the line under Increased Contrast instead
    /// (`theAccentHoldsTheLineUnderIncreasedContrast`), the gold is a mark.
    @Test(arguments: [
        ("tint", Palette.tint), ("secondary", Palette.secondary),
    ])
    func aGlyphRoleReadsOnEveryGround(_ role: (String, UIColor)) {
        let appearances = role.0 == "tint" ? [Self.traits(.light, high: true), Self.dark] : [Self.light, Self.dark]
        for traits in appearances {
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
        // The light pink is a mark, not text strength (#1190): its text role
        // reads under Increased Contrast.
        let appearances = role.0 == "brandText" ? [Self.traits(.light, high: true), Self.dark] : [Self.light, Self.dark]
        for traits in appearances {
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
            // The light pink fill under white is the owner's call (#1190);
            // Increased Contrast keeps it legible.
            let lightTraits = name.hasPrefix("onPrimary ") || name == "onPrimary" ? Self.traits(.light, high: true) : Self.light
            for traits in [lightTraits, Self.dark] {
                let ratio = Self.contrast(text, on: ground, traits)
                #expect(ratio >= 4.5, "\(name) is \(ratio):1")
            }
        }
    }

    /// The pink fill wears a WHITE label in the light; the light pink is
    /// the owner's (#1190), and Increased Contrast deepens the fill so the
    /// label reads at 4.5:1.
    @Test func whiteReadsOnTheFillInTheLight() {
        #expect(Self.hex(Palette.primaryFill, Self.light) == 0xF37AB4)
        #expect(Self.contrast(.white, on: Palette.primaryFill, Self.traits(.light, high: true)) >= 4.5)
        #expect(Self.hex(Palette.onPrimary, Self.light) == 0xFFFFFF)
    }

    /// The light pink is the dark theme's (#1190); Increased Contrast keeps a
    /// deep pink that reads as a glyph and as text.
    @Test func theAccentHoldsTheLineUnderIncreasedContrast() {
        #expect(Self.hex(Palette.tint, Self.light) == 0xF37AB4)
        for ground in [UIColor.systemBackground, .secondarySystemBackground] {
            #expect(Self.contrast(Palette.tint, on: ground, Self.traits(.light, high: true)) >= 4.5)
        }
    }

    /// Increased Contrast resolves to the IC values.
    @Test func increasedContrastResolvesToItsOwnValues() {
        #expect(Self.hex(Palette.tint, Self.traits(.light)) == 0xF37AB4)
        #expect(Self.hex(Palette.tint, Self.traits(.dark)) == 0xF37AB4)
        #expect(Self.hex(Palette.tint, Self.traits(.light, high: true)) == 0xB0256A)
        #expect(Self.hex(Palette.tint, Self.traits(.dark, high: true)) == 0xF8ABCF)
        #expect(Self.hex(Palette.secondary, Self.traits(.light, high: true)) == 0x5C44B7)
        #expect(Self.hex(Palette.secondary, Self.traits(.dark, high: true)) == 0xB59EFF)
        // The fill deepens under Increased Contrast (#1190); a role without
        // IC values keeps its ordinary one.
        #expect(Self.hex(Palette.primaryFill, Self.traits(.light, high: true)) == 0xB0256A)
        #expect(Self.hex(Palette.saveGold, Self.traits(.light, high: true)) == 0xFFC53D)
    }

    /// The heart is the pink, solid (#1178) — two equal stops, so the
    /// gradient layer still draws — the light pink in both appearances since
    /// #1190; under Increased Contrast it reads at 3:1 on the page.
    @Test func thePointsHeartIsThePink() {
        #expect(PointsSymbol.gradient(for: Self.light).map { Self.hex($0, Self.light) } == [0xF37AB4, 0xF37AB4])
        #expect(PointsSymbol.gradient(for: Self.dark).map { Self.hex($0, Self.dark) } == [0xF37AB4, 0xF37AB4])
        for traits in [Self.traits(.light, high: true), Self.dark] {
            for stop in PointsSymbol.gradient(for: traits) {
                #expect(Self.contrast(stop, on: .systemBackground, traits) >= 3)
            }
        }
        #expect(PointsSymbol.tint === Palette.tint)
    }

    /// Links and tokens in text (#1174): a greyed violet (#1176) — blue over
    /// green, little chroma — that reads at 4.5:1 on the page and on the
    /// grouped grey, in every appearance and contrast.
    @Test func theEntityInkIsAGreyedVioletThatReadsAsText() {
        for traits in [Self.light, Self.dark, Self.traits(.light, high: true), Self.traits(.dark, high: true)] {
            for ground in [UIColor.systemBackground, .secondarySystemBackground] {
                let ratio = Self.contrast(Palette.entityInk, on: ground, traits)
                #expect(ratio >= 4.5, "\(ratio):1 in \(traits.userInterfaceStyle.rawValue)")
            }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            Palette.entityInk.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            #expect(b > r && r > g, "violet: blue, then red, over green")
            #expect(max(r, g, b) - min(r, g, b) < 0.25, "greyed: little chroma")
        }
    }

    /// The hues the palette took over (#1124): gems are violet, a warning's
    /// glyph is yellow — orange is the tint's now.
    @Test func gemsAreVioletAndWarningsYellow() {
        #expect(GemSymbol.tint === Palette.secondary)
        #expect(ToastView.Style.warning.glyphTint == .systemYellow)
    }

    /// A warning (#1124, owner 2026-10-14): a yellow glyph, the words in the
    /// neutral ink — never yellow or orange text.
    @Test func aWarningNoteIsAYellowGlyphAndNeutralWords() {
        let note = Warning.note("Full", font: .systemFont(ofSize: 12))
        var sawGlyph = false
        note.enumerateAttribute(.attachment, in: NSRange(location: 0, length: note.length)) { value, _, _ in
            if value is NSTextAttachment { sawGlyph = true }
        }
        #expect(sawGlyph)
        let ink = note.attribute(.foregroundColor, at: note.length - 1, effectiveRange: nil) as? UIColor
        #expect(ink == .secondaryLabel)
        #expect(note.string.hasSuffix("Full"))
    }

    /// A prominent glass button wears the primary pink in both appearances
    /// (#1190) — the glass draws its label white whatever the ink.
    @Test func theProminentGlassTintIsThePrimaryPink() {
        for traits in [Self.light, Self.dark] {
            #expect(Self.hex(Palette.prominentGlassTint, traits) == 0xF37AB4)
        }
    }
}
