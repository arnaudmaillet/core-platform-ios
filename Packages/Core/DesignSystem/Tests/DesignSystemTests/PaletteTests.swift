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
    /// raised ground, in both appearances and both contrasts — the primary
    /// `FF1358` (#2282) holds it without Increased Contrast: 3.43:1 on the
    /// light grouped grey, its lowest.
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
    /// card. The primary's text under Increased Contrast here (its ordinary
    /// values: `thePrimarysTextShadeReads`); the gems' price and the links
    /// in every appearance.
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
    /// 3.8:1 (`FF1358`'s own, 3.83, #2282: a semibold label at the button's
    /// size, past 3:1) and 4.5:1 under Increased Contrast; the soft
    /// container's text at 4.5:1 everywhere.
    @Test func theLabelsOnBrandGroundsRead() {
        let normal = [Self.light, Self.dark]
        let high = [Self.traits(.light, high: true), Self.traits(.dark, high: true)]
        let pairs: [(String, UIColor, UIColor, CGFloat)] = [
            ("onPrimary", Palette.onPrimary, Palette.primaryFill, 3.8),
            ("onPrimary pressed", Palette.onPrimary, Palette.primaryFillPressed, 4.5),
            ("onPrimaryContainer", Palette.onPrimaryContainer, Palette.primaryContainer, 4.5),
            ("a count on the unread mark", .white, Palette.counter, 3.8),
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
            ("tint", Palette.tint, theme.primary), ("brandText", Palette.brandText, theme.primaryText),
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
        // The story ring wears the signature itself (#2282), its IC stops
        // with Increased Contrast.
        for appearance in [Self.light, Self.dark] {
            #expect(Palette.storyRingGradient.map { Self.hex($0, appearance) } == theme.signatureGradient)
        }
        for appearance in [Self.traits(.light, high: true), Self.traits(.dark, high: true)] {
            #expect(Palette.storyRingGradient.map { Self.hex($0, appearance) } == theme.signatureContrastStops)
        }
        #expect(Palette.storyRingGradientLocations.map(\.doubleValue) == theme.signatureLocations)
        // The loader (#2340): the primary's three steps in both appearances,
        // the primary's IC value under Increased Contrast.
        for appearance in [Self.light, Self.dark] {
            #expect(Palette.loaderPillColors.map { Self.hex($0, appearance) } == theme.loaderSteps)
        }
        #expect(Palette.loaderPillColors.map { Self.hex($0, Self.traits(.light, high: true)) }
                == Array(repeating: theme.primary.lightIC, count: theme.loaderSteps.count))
        #expect(Palette.loaderPillColors.map { Self.hex($0, Self.traits(.dark, high: true)) }
                == Array(repeating: theme.primary.darkIC, count: theme.loaderSteps.count))
        #expect(theme.loaderSteps.first == theme.primary.light, "the loader's first pill is the primary")
    }

    /// The owner's values (#2282, 2026-11-11), as asked.
    @Test func theThemeIsCoral() {
        let theme = BrandTheme.current
        #expect(theme == BrandTheme.coral)
        for appearance in [Self.light, Self.dark] {
            #expect(Self.hex(Palette.tint, appearance) == 0xFF1358)
            #expect(Self.hex(Palette.primaryFill, appearance) == 0xFF1358)
            #expect(Self.hex(Palette.prominentFill, appearance) == 0xFF1358)
            #expect(Self.hex(Palette.counter, appearance) == 0xFF1358, "unread marks are the primary")
            #expect(Self.hex(Palette.likesPink, appearance) == 0xFF1358)
        }
        #expect(Self.hex(Palette.brandText, Self.light) == 0xEB0045, "the primary's text shade, deeper in the light")
        #expect(Self.hex(Palette.brandText, Self.dark) == 0xFF1358)
        #expect(theme.accent.dark == 0x16FFCB, "the mint, on dark grounds")
        // The signature (#2282): violet → mint, two stops, at 0 and 1.
        #expect(Palette.brandGradient.map { Self.hex($0, Self.light) } == [0x7235FF, 0x16FFCB])
        // The story ring (#2089) wears it, the deep mint end under
        // Increased Contrast.
        for appearance in [Self.light, Self.dark] {
            #expect(Palette.storyRingGradient.map { Self.hex($0, appearance) } == [0x7235FF, 0x16FFCB])
        }
        for appearance in [Self.traits(.light, high: true), Self.traits(.dark, high: true)] {
            #expect(Palette.storyRingGradient.map { Self.hex($0, appearance) } == [0x7235FF, 0x009E7B])
        }
        #expect(Palette.storyRingGradientLocations == [0, 1])
        #expect(Self.hex(Palette.saveGold, Self.light) == 0xFFC53D, "the saved star keeps its gold")
        #expect(Self.hex(Palette.gem, Self.dark) == 0xFFE600, "the gems keep the crown's yellow")
    }

    /// The violet appears only inside the signature (#2282): no role is it,
    /// in any appearance — nor the mint, which is not a UI colour (§ 3).
    @Test func theVioletAndTheMintAreNoRole() {
        let roles: [UIColor] = [
            Palette.tint, Palette.brandText, Palette.primaryFill, Palette.onPrimary, Palette.primaryFillPressed,
            Palette.prominentFill, Palette.prominentGlassTint, Palette.primaryContainer, Palette.onPrimaryContainer,
            Palette.counter, Palette.entityInk, Palette.likesPink, Palette.gem, Palette.gemText, Palette.gemGround,
        ]
        let signature = Set(BrandTheme.current.signatureGradient + BrandTheme.current.signatureContrastStops)
        for colour in roles {
            for appearance in [Self.light, Self.dark, Self.traits(.light, high: true), Self.traits(.dark, high: true)] {
                #expect(!signature.contains(Self.hex(colour, appearance)), "a role wears the signature's colour")
            }
        }
    }

    /// The primary's TEXT shade (#2282): `FF1358` is 3.83:1 on white, under
    /// small text's 4.5:1, so text in the light wears a deeper shade of the
    /// same hue — 4.55:1 on white and on the card. Increased Contrast takes
    /// it past 5.5:1 in the light and lifts it past 7:1 on black.
    @Test func thePrimarysTextShadeReads() {
        for ground in [UIColor.systemBackground, .secondarySystemGroupedBackground] {
            let ratio = Self.contrast(Palette.brandText, on: ground, Self.light)
            #expect(ratio >= 4.5, "brandText is \(ratio):1 in the light")
        }
        let onBlack = Self.contrast(Palette.brandText, on: .systemBackground, Self.dark)
        #expect(onBlack >= 4.5, "brandText is \(onBlack):1 on black")
        let deeper = Self.contrast(Palette.brandText, on: .white, Self.light)
        #expect(deeper > Self.contrast(Palette.tint, on: .white, Self.light), "the text shade is not deeper")
        let highLight = Self.contrast(Palette.brandText, on: .white, Self.traits(.light, high: true))
        #expect(highLight >= 5.5, "brandText is \(highLight):1 on white under Increased Contrast")
        let highDark = Self.contrast(Palette.brandText, on: .black, Self.traits(.dark, high: true))
        #expect(highDark >= 7, "brandText is \(highDark):1 on black under Increased Contrast")
        // The white label on the Increased Contrast fill, 5.5:1 too.
        for appearance in [Self.traits(.light, high: true), Self.traits(.dark, high: true)] {
            let label = Self.contrast(Palette.onPrimary, on: Palette.primaryFill, appearance)
            #expect(label >= 5.5, "onPrimary is \(label):1 under Increased Contrast")
        }
        // The same hue: the text shade only deepens the primary.
        func hue(_ colour: UIColor) -> CGFloat {
            var value: CGFloat = 0
            colour.resolvedColor(with: Self.light).getHue(&value, saturation: nil, brightness: nil, alpha: nil)
            return value * 360
        }
        #expect(abs(hue(Palette.brandText) - hue(Palette.tint)) < 2, "the text shade changed hue")
    }

    /// The mint (#2282): `16FFCB` on dark grounds, a deep mint on light ones
    /// — the mint itself is 1.30:1 on white — a glyph's 3:1 on the light
    /// page, text's 4.5:1 on white. Never white words on the mint. It is the
    /// signature's end, and its deep mint the end under Increased Contrast.
    @Test func theMintAccentReadsWhereItIsDrawn() {
        let theme = BrandTheme.current
        func ratio(_ ink: UInt32, _ ground: UInt32) -> CGFloat {
            Self.contrast(Palette.rgb(ink), on: Palette.rgb(ground), Self.light)
        }
        let page: UInt32 = 0xF2F2F7
        #expect(ratio(theme.accent.light, page) >= 3, "the deep mint glyph on the light page")
        #expect(ratio(theme.accent.lightIC, 0xEBEBF0) >= 3, "the IC deep mint on the IC light grey")
        #expect(ratio(theme.accentText.light, 0xFFFFFF) >= 4.5, "the deep mint text on white")
        #expect(ratio(theme.accentText.lightIC, 0xFFFFFF) >= ratio(theme.accentText.light, 0xFFFFFF))
        for ground: UInt32 in [0x000000, 0x1C1C1E, 0x242426] {
            #expect(ratio(theme.accent.dark, ground) >= 4.5, "the mint on a dark ground")
            #expect(ratio(theme.accentText.darkIC, ground) >= 4.5)
        }
        #expect(ratio(0xFFFFFF, theme.accent.dark) < 1.5, "the mint carries no white words")
        #expect(theme.signatureGradient.last == theme.accent.dark, "the signature ends on the mint")
        #expect(theme.signatureContrastStops.last == theme.accent.light, "the IC end is the deep mint")
        #expect(ratio(theme.signatureContrastStops.last ?? 0, page) >= 3)
    }

    /// The heart is the primary, solid (#1178) — two equal stops, so the
    /// gradient layer still draws.
    @Test func theLikesHeartIsThePrimary() {
        for traits in [Self.light, Self.dark] {
            let stops = LikesSymbol.gradient(for: traits).map { Self.hex($0, traits) }
            #expect(stops == [0xFF1358, 0xFF1358])
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
            #expect(Self.hex(Palette.prominentGlassTint, traits) == 0xFF1358)
        }
    }
}
