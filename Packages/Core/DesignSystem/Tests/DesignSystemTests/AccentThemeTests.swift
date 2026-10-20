import Testing
import UIKit
@testable import DesignSystem

/// The accent themes (#1379): every themed role resolves in every theme,
/// appearance and contrast and keeps the contrast its use needs; the
/// economy's colours never follow the theme; the choice is kept per account.
@MainActor
struct AccentThemeTests {
    private static func traits(
        _ theme: AccentTheme, _ style: UIUserInterfaceStyle = .light, high: Bool = false
    ) -> UITraitCollection {
        UITraitCollection(mutations: {
            $0.accentTheme = theme
            $0.userInterfaceStyle = style
            $0.accessibilityContrast = high ? .high : .normal
        })
    }

    private static let roles: [(String, UIColor)] = [
        ("tint", Palette.tint), ("brandText", Palette.brandText), ("primaryFill", Palette.primaryFill),
        ("onPrimary", Palette.onPrimary), ("primaryFillPressed", Palette.primaryFillPressed),
        ("prominentGlassTint", Palette.prominentGlassTint), ("primaryContainer", Palette.primaryContainer),
        ("onPrimaryContainer", Palette.onPrimaryContainer), ("secondary", Palette.secondary),
        ("secondaryContainer", Palette.secondaryContainer), ("onSecondaryContainer", Palette.onSecondaryContainer),
        ("counterViolet", Palette.counterViolet),
    ]

    private static func hex(_ colour: UIColor, _ traits: UITraitCollection) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        colour.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return UInt32((r * 255).rounded()) << 16 | UInt32((g * 255).rounded()) << 8 | UInt32((b * 255).rounded())
    }

    /// WCAG relative luminance contrast of two resolved colours.
    private static func contrast(_ a: UIColor, _ b: UIColor, _ traits: UITraitCollection) -> CGFloat {
        func luminance(_ colour: UIColor) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
            colour.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &alpha)
            func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }

    @Test(arguments: AccentTheme.allCases)
    func everyRoleResolvesOpaqueInEveryAppearance(_ theme: AccentTheme) {
        for (role, colour) in Self.roles {
            for (style, high) in [(UIUserInterfaceStyle.light, false), (.dark, false), (.light, true), (.dark, true)] {
                var alpha: CGFloat = 0
                colour.resolvedColor(with: Self.traits(theme, style, high: high)).getRed(nil, green: nil, blue: nil, alpha: &alpha)
                #expect(alpha == 1, "\(role) is not opaque in \(theme)")
            }
        }
    }

    /// Each theme's accent, and pink is the default a trait carries.
    @Test func eachThemeHasItsAccent() {
        #expect(UITraitCollection().accentTheme == .pink)
        #expect(Self.hex(Palette.tint, Self.traits(.pink)) == 0xF37AB4)
        #expect(Self.hex(Palette.tint, Self.traits(.violet)) == 0xA78BFA)
        #expect(Self.hex(Palette.tint, Self.traits(.red)) == 0xE5484D)
        #expect(Self.hex(Palette.tint, UITraitCollection(userInterfaceStyle: .light)) == 0xF37AB4)
    }

    /// The accent holds the line as pink's does (#1190): text-strong on black,
    /// and on white under Increased Contrast; a filled button's label reads
    /// where the fill carries it; a white count reads on the counter.
    @Test(arguments: AccentTheme.allCases)
    func theAccentReadsInEveryTheme(_ theme: AccentTheme) {
        let (dark, lightIC, darkIC) = (Self.traits(theme, .dark), Self.traits(theme, high: true), Self.traits(theme, .dark, high: true))
        for role in [Palette.tint, Palette.brandText] {
            #expect(Self.contrast(role, .black, dark) >= 4.5, "\(theme) accent on black")
            #expect(Self.contrast(role, .white, lightIC) >= 4.5, "\(theme) accent on white, IC")
            #expect(Self.contrast(role, .black, darkIC) >= 4.5, "\(theme) accent on black, IC")
        }
        for traits in [lightIC, dark] {
            let onFill = Self.contrast(Palette.onPrimary, Palette.primaryFill, traits)
            #expect(onFill >= 4.5, "\(theme) onPrimary \(onFill):1")
        }
        for traits in [Self.traits(theme), dark] {
            let onContainer = Self.contrast(Palette.onPrimaryContainer, Palette.primaryContainer, traits)
            #expect(onContainer >= 4.5, "\(theme) onPrimaryContainer \(onContainer):1")
            let onSecondary = Self.contrast(Palette.onSecondaryContainer, Palette.secondaryContainer, traits)
            #expect(onSecondary >= 4.5, "\(theme) onSecondaryContainer \(onSecondary):1")
            let secondary = Self.contrast(Palette.secondary, traits.userInterfaceStyle == .dark ? .black : .white, traits)
            #expect(secondary >= 4.5, "\(theme) secondary \(secondary):1")
        }
        #expect(Self.contrast(.white, Palette.counterViolet, Self.traits(theme)) >= 4.5, "\(theme) white count")
    }

    /// Violet swaps the two hues: the secondary turns pink, the gradient runs
    /// violet → pink.
    @Test func theVioletThemeSwapsTheHues() {
        let violet = Self.traits(.violet)
        #expect(Palette.accentGradient.map { Self.hex($0, violet) } == [0xA78BFA, 0xF37AB4])
        #expect(Self.hex(Palette.secondary, violet) == 0xB8296C)
        #expect(Self.hex(Palette.secondary, Self.traits(.red)) == 0x6852C6)
        #expect(Palette.accentGradient.map { Self.hex($0, Self.traits(.red)) } == [0xE5484D, 0xA78BFA])
    }

    /// The economy's colours, the links' ink and the brand's own gradient
    /// never follow the theme.
    @Test func theEconomyNeverFollowsTheTheme() {
        for (style, high) in [(UIUserInterfaceStyle.light, false), (.dark, false), (.light, true), (.dark, true)] {
            let pink = Self.traits(.pink, style, high: high)
            for theme in AccentTheme.allCases {
                let traits = Self.traits(theme, style, high: high)
                #expect(Self.hex(Palette.likesPink, traits) == Self.hex(Palette.likesPink, pink))
                #expect(Self.hex(Palette.gemViolet, traits) == Self.hex(Palette.gemViolet, pink))
                #expect(Self.hex(Palette.entityInk, traits) == Self.hex(Palette.entityInk, pink))
                #expect(Palette.likesGradient(for: traits).map { Self.hex($0, traits) }
                    == Palette.likesGradient(for: pink).map { Self.hex($0, pink) })
            }
            // The pink theme is the palette as it was.
            #expect(Self.hex(Palette.likesPink, pink) == Self.hex(Palette.tint, pink))
            #expect(Self.hex(Palette.gemViolet, pink) == Self.hex(Palette.secondary, pink))
        }
        #expect(GemSymbol.tint === Palette.gemViolet)
        #expect(LikesSymbol.tint === Palette.likesPink)
    }

    /// A window wears the applied theme, and what it holds resolves in it.
    @Test func aWindowDrawsInItsTheme() {
        let window = AppWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(window.traitOverrides.accentTheme == AccentThemePreference.applied)
        let view = UIView()
        window.addSubview(view)
        window.traitOverrides.accentTheme = .red
        window.layoutIfNeeded()
        #expect(view.traitCollection.accentTheme == .red)
        #expect(Self.hex(Palette.tint, view.traitCollection) == 0xE5484D)
    }

    @Test func aLaunchArgumentNamesATheme() {
        #expect(AccentThemePreference.resolve(arguments: ["app", "-theme", "violet"]) == .violet)
        #expect(AccentThemePreference.resolve(arguments: ["app", "-theme", "red"]) == .red)
        #expect(AccentThemePreference.resolve(arguments: ["app", "-theme", "teal"]) == nil)
        #expect(AccentThemePreference.resolve(arguments: ["app", "-theme"]) == nil)
        #expect(AccentThemePreference.resolve(arguments: ["app"]) == nil)
    }

    /// Kept per account on the device; a guest and an account that never
    /// chose are pink. Synchronous: the swapped defaults never cross an
    /// `await`.
    @Test func theThemeIsKeptPerAccount() throws {
        let suite = "AccentThemeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let saved = AccentThemePreference.defaults
        AccentThemePreference.defaults = defaults
        defer {
            AccentThemePreference.defaults = saved
            defaults.removePersistentDomain(forName: suite)
        }
        #expect(AccentThemePreference.theme(for: nil) == .pink)
        #expect(AccentThemePreference.theme(for: "a") == .pink)
        AccentThemePreference.setTheme(.violet, for: "a")
        AccentThemePreference.setTheme(.red, for: "b")
        #expect(AccentThemePreference.theme(for: "a") == .violet)
        #expect(AccentThemePreference.theme(for: "b") == .red)
        #expect(AccentThemePreference.theme(for: nil) == .pink)
        AccentThemePreference.setTheme(.pink, for: "a")
        #expect(AccentThemePreference.theme(for: "a") == .pink)
        #expect((defaults.dictionary(forKey: AccentThemePreference.key) as? [String: String]) == ["b": "red"])
        // A launch starts in the theme last applied on the device, so a
        // violet app never opens pink first; pink before any.
        #expect(AccentThemePreference.lastApplied == .pink)
        defaults.set("violet", forKey: AccentThemePreference.lastAppliedKey)
        #expect(AccentThemePreference.lastApplied == .violet)
    }

    @Test func aThemeNamesItsCatalogueItem() {
        #expect(AccentTheme.allCases.map(\.itemID) == ["theme.pink", "theme.violet", "theme.red"])
    }
}
