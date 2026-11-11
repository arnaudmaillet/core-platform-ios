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
    /// raised ground, in both appearances and both contrasts — the
    /// raspberry (#2062) holds it without Increased Contrast, unlike the
    /// light pink it replaced.
    @Test(arguments: [
        ("tint", Palette.tint), ("likes", Palette.likesPink),
    ])
    func aGlyphRoleReadsOnEveryGround(_ role: (String, UIColor)) {
        for traits in [Self.light, Self.dark, Self.traits(.light, high: true), Self.traits(.dark, high: true)] {
            for ground in [UIColor.systemBackground, .secondarySystemBackground] {
                let ratio = Self.contrast(role.1, on: ground, traits)
                #expect(ratio >= 3, "\(role.0) is \(ratio):1 in \(traits.userInterfaceStyle == .dark ? "dark" : "light")")
            }
        }
    }

    /// The crown (#2071) is the owner's bright gold in the light (2026-11-03),
    /// under a glyph's 3:1 there, since it always stands beside its amount;
    /// it holds 3:1 in the dark and under Increased Contrast in both.
    @Test func theCrownReadsWhereItMust() {
        #expect(Self.hex(Palette.gem, Self.light) == 0xF5C000)
        for traits in [Self.dark, Self.traits(.light, high: true), Self.traits(.dark, high: true)] {
            for ground in [UIColor.systemBackground, .secondarySystemBackground] {
                let ratio = Self.contrast(Palette.gem, on: ground, traits)
                #expect(ratio >= 3, "gem is \(ratio):1 in \(traits.userInterfaceStyle == .dark ? "dark" : "light")")
            }
        }
    }

    /// Text roles: 4.5:1 on the grounds body text lies on — the page and a
    /// card. The accent's text reaches it under Increased Contrast (the
    /// raspberry itself is 4.2:1 on white, the owner's base 500, #2062); the
    /// gems' price and the links in every appearance.
    @Test(arguments: [
        ("brandText", Palette.brandText, true), ("gemText", Palette.gemText, false),
        ("entityInk", Palette.entityInk, false),
    ])
    func aTextRoleReadsAsText(_ role: (String, UIColor, Bool)) {
        let highOnly = [Self.traits(.light, high: true), Self.traits(.dark, high: true)]
        let appearances = role.2 ? highOnly : [Self.light, Self.dark] + highOnly
        for traits in appearances {
            for ground in [UIColor.systemBackground, .secondarySystemGroupedBackground] {
                let ratio = Self.contrast(role.1, on: ground, traits)
                #expect(ratio >= 4.5, "\(role.0) is \(ratio):1 in \(traits.userInterfaceStyle == .dark ? "dark" : "light")")
            }
        }
    }

    /// The text that sits on a brand ground: a white label on the fill at
    /// 4.2:1 (the raspberry's own, #2062) and 4.5:1 under Increased
    /// Contrast; the soft container's text at 4.5:1 everywhere.
    @Test func theLabelsOnBrandGroundsRead() {
        let normal = [Self.light, Self.dark]
        let high = [Self.traits(.light, high: true), Self.traits(.dark, high: true)]
        let pairs: [(String, UIColor, UIColor, CGFloat)] = [
            ("onPrimary", Palette.onPrimary, Palette.primaryFill, 4.2),
            ("onPrimary pressed", Palette.onPrimary, Palette.primaryFillPressed, 4.5),
            ("onPrimaryContainer", Palette.onPrimaryContainer, Palette.primaryContainer, 4.5),
            ("a count on the unread mark", .white, Palette.counter, 4.2),
        ]
        for (name, text, ground, floor) in pairs {
            for traits in normal {
                let ratio = Self.contrast(text, on: ground, traits)
                #expect(ratio >= floor, "\(name) is \(ratio):1")
            }
            for traits in high {
                let ratio = Self.contrast(text, on: ground, traits)
                #expect(ratio >= 4.5, "\(name) is \(ratio):1 under Increased Contrast")
            }
        }
    }

    /// A tinted row action's words in the dark (#2231): the container's
    /// words on the wash, 4.5:1, body-size text's.
    @Test func aRowActionsWordsReadInTheDark() {
        for traits in [Self.dark, Self.traits(.dark, high: true)] {
            let tinted = Self.contrast(Palette.onPrimaryContainer, on: Palette.primaryContainer, traits)
            #expect(tinted >= 4.5, "tinted row-action words are \(tinted):1 in the dark")
        }
    }

    /// Every role resolves to `BrandTheme.current`'s values, per appearance
    /// and contrast: no role holds a value of its own.
    @Test func everyRoleIsTheThemes() {
        let theme = BrandTheme.current
        let roles: [(String, UIColor, BrandTheme.Shade)] = [
            ("tint", Palette.tint, theme.primary), ("brandText", Palette.brandText, theme.primary),
            ("primaryFill", Palette.primaryFill, theme.primaryFill),
            ("onPrimary", Palette.onPrimary, theme.onPrimary),
            ("primaryFillPressed", Palette.primaryFillPressed, theme.primaryPressed),
            ("prominentFill", Palette.prominentFill, theme.primarySolid),
            ("prominentGlassTint", Palette.prominentGlassTint, theme.primarySolid),
            ("primaryContainer", Palette.primaryContainer, theme.primaryContainer),
            ("onPrimaryContainer", Palette.onPrimaryContainer, theme.onPrimaryContainer),
            ("counter", Palette.counter, theme.counter), ("entityInk", Palette.entityInk, theme.entityInk),
            ("likes", Palette.likesPink, theme.likes), ("gem", Palette.gem, theme.gem),
            ("gemText", Palette.gemText, theme.gemText),
        ]
        for (name, colour, shade) in roles {
            #expect(Self.hex(colour, Self.traits(.light)) == shade.light, "\(name) light")
            #expect(Self.hex(colour, Self.traits(.dark)) == shade.dark, "\(name) dark")
            #expect(Self.hex(colour, Self.traits(.light, high: true)) == shade.lightIC, "\(name) IC light")
            #expect(Self.hex(colour, Self.traits(.dark, high: true)) == shade.darkIC, "\(name) IC dark")
        }
        #expect(Self.hex(Palette.saveGold, Self.light) == theme.saveGold)
        #expect(Palette.brandGradient.map { Self.hex($0, Self.light) } == theme.signatureGradient)
        #expect(Palette.brandGradientLocations.map(\.doubleValue) == theme.signatureLocations)
        #expect(Palette.storyRingGradient.map { Self.hex($0, Self.light) } == theme.storyRingGradient)
        #expect(Palette.storyRingGradientLocations.map(\.doubleValue) == theme.storyRingLocations)
        #expect(Palette.loaderGradient(highContrast: false).map { Self.hex($0, Self.light) } == theme.signatureGradient)
        #expect(Palette.loaderGradient(highContrast: true).map { Self.hex($0, Self.light) } == theme.loaderContrastStops)
    }

    /// The owner's values (#2062), as asked.
    @Test func theThemeIsRaspberry() {
        #expect(Self.hex(Palette.tint, Self.light) == 0xEC1C75)
        #expect(Self.hex(Palette.tint, Self.dark) == 0xEC1C75)
        #expect(Self.hex(Palette.counter, Self.light) == 0xEC1C75, "unread marks are the raspberry, no longer violet")
        #expect(Palette.brandGradient.map { Self.hex($0, Self.light) } == [0xEC1C75, 0x9B5CFF, 0x2EF0A8])
        // The story ring (#2089): raspberry → violet, no mint, at 0 and 1.
        for traits in [Self.light, Self.dark] {
            #expect(Palette.storyRingGradient.map { Self.hex($0, traits) } == [0xEC1C75, 0x9B5CFF])
        }
        #expect(Palette.storyRingGradientLocations == [0, 1])
        #expect(Self.hex(Palette.saveGold, Self.light) == 0xFFC53D, "the saved star keeps its gold")
    }

    /// The heart is the primary, solid (#1178) — two equal stops, so the
    /// gradient layer still draws.
    @Test func theLikesHeartIsThePrimary() {
        for traits in [Self.light, Self.dark] {
            let stops = LikesSymbol.gradient(for: traits).map { Self.hex($0, traits) }
            #expect(stops == [0xEC1C75, 0xEC1C75])
        }
        #expect(LikesSymbol.tint === Palette.likesPink)
    }

    /// Links and tokens in text (#2062): a grey with no cast.
    @Test func theEntityInkIsANeutralGrey() {
        for traits in [Self.light, Self.dark, Self.traits(.light, high: true), Self.traits(.dark, high: true)] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            Palette.entityInk.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            #expect(max(r, g, b) - min(r, g, b) < 0.04, "a grey: next to no chroma")
        }
    }

    /// The gems wear the crown's gold — the glyph, and a deeper step where it
    /// is a price — and a warning's glyph is yellow.
    @Test func gemsAreGoldAndWarningsYellow() {
        #expect(GemSymbol.tint === Palette.gem)
        #expect(GemSymbol.textColor === Palette.gemText)
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

    /// A prominent glass button wears the primary in both appearances —
    /// the glass draws its label white whatever the ink.
    @Test func theProminentGlassTintIsThePrimary() {
        for traits in [Self.light, Self.dark] {
            #expect(Self.hex(Palette.prominentGlassTint, traits) == 0xEC1C75)
        }
    }
}
