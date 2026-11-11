import Foundation
import Testing
@testable import DesignSystem

/// ⚠️ THE ASSETS HOLD THE BRAND TOO (#2062). `AccentColor`, the launch logo
/// and the app icon carry colours outside the code, where `BrandTheme`
/// cannot reach them: a theme change that forgets one ships the old brand
/// in a corner — the light `AccentColor` was `D6337F` while the app drew in
/// `F37AB4`, and nothing said so. This reads each file in the repository and
/// checks it against `BrandTheme.current`.
///
/// ⚠️ #2282 IN TWO PULL REQUESTS: the first moves the theme (`coral`), the
/// second redraws the icon and the launch logo. Until then those two still
/// wear the raspberry signature, which the theme no longer holds, so they
/// are checked against `UntilTheNewIcon` below — PR 2 (#2282, 2/2) replaces
/// it with the new icon's guard (its ground is `primary`, its mint layer
/// `accent`, the launch logo's colours the theme's). `AccentColor` is
/// checked against the theme already.
///
/// CI only runs this in DesignSystem's lane: changing an asset's colour, run
/// DesignSystem's tests too.
struct BrandAssetsGuardTests {
    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignSystemTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // DesignSystem
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }

    private static func read(_ path: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(path))
    }

    private static let theme = BrandTheme.current

    /// ⚠️ PR 2 (#2282, 2/2) REPLACES THIS: what the icon and the launch logo
    /// hold today — #2062's raspberry → violet → mint signature, which
    /// `BrandTheme` dropped with #2282's first pull request. Pinned here, in
    /// a test (out of `RawHueGuardTests`' reach), so the guard still fails
    /// on an asset that drifts until the new icon lands.
    enum UntilTheNewIcon {
        /// `LaunchLogo.svg`'s pale gradient stops, first to last.
        static let launchLogoStops: [UInt32] = [0xF699C1, 0xD2B6FF, 0xA1F8D8]
        /// `circle.svg`'s blob gradient, first stop to last, and each stop's
        /// opacity.
        static let iconStops: [UInt32] = [0xEC1C75, 0x9B5CFF, 0x2EF0A8]
        static let iconOpacities: [Double] = [0.75, 0.6, 0.55]
    }

    /// A colorset's values by appearance: "light", "dark", "lightIC",
    /// "darkIC".
    static func accentColorValues(_ data: Data) throws -> [String: UInt32] {
        struct Colorset: Decodable {
            struct Entry: Decodable {
                struct Colour: Decodable {
                    let components: [String: String]
                }
                struct Appearance: Decodable {
                    let appearance: String
                    let value: String
                }
                let color: Colour
                let appearances: [Appearance]?
            }
            let colors: [Entry]
        }
        var found: [String: UInt32] = [:]
        for entry in try JSONDecoder().decode(Colorset.self, from: data).colors {
            let appearances = entry.appearances ?? []
            let dark = appearances.contains { $0.appearance == "luminosity" && $0.value == "dark" }
            let high = appearances.contains { $0.appearance == "contrast" && $0.value == "high" }
            func channel(_ name: String) -> UInt32 {
                let text = entry.color.components[name] ?? ""
                return UInt32(text.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? .max
            }
            found[(dark ? "dark" : "light") + (high ? "IC" : "")] = channel("red") << 16 | channel("green") << 8 | channel("blue")
        }
        return found
    }

    /// What `AccentColor` must hold: the primary's four values.
    static func expectedAccentColor(_ theme: BrandTheme) -> [String: UInt32] {
        ["light": theme.primary.light, "dark": theme.primary.dark,
         "lightIC": theme.primary.lightIC, "darkIC": theme.primary.darkIC]
    }

    /// An SVG's gradient stops, first to last, as upper-case hex.
    static func svgStops(_ svg: String) -> [String] {
        svg.components(separatedBy: "stop-color=\"#").dropFirst().map { String($0.prefix(6)).uppercased() }
    }

    static func hex(_ value: UInt32) -> String { String(format: "%06X", value) }

    /// `AccentColor`'s four values are the primary's: light, dark, and the
    /// Increased Contrast pair.
    @Test func theAccentColorIsThePrimary() throws {
        let found = try Self.accentColorValues(
            Self.read("App/Resources/Assets.xcassets/AccentColor.colorset/Contents.json")
        )
        #expect(found == Self.expectedAccentColor(Self.theme))
    }

    /// The launch logo's gradient stops, first to last (PR 2 replaces it).
    @Test func theLaunchLogoWearsItsStops() throws {
        let svg = String(decoding: try Self.read("App/Resources/Assets.xcassets/LaunchLogo.imageset/LaunchLogo.svg"), as: UTF8.self)
        #expect(Self.svgStops(svg) == UntilTheNewIcon.launchLogoStops.map(Self.hex))
    }

    /// The icon's blob: its stops, drawn by `circle.svg` — and no layer fill
    /// in `icon.json` painting over them (PR 2 replaces it).
    @Test func theIconWearsItsGradient() throws {
        let svg = String(decoding: try Self.read("App/Resources/AppIcon.icon/Assets/circle.svg"), as: UTF8.self)
        #expect(Self.svgStops(svg) == UntilTheNewIcon.iconStops.map(Self.hex))
        let opacities = svg.components(separatedBy: "stop-opacity=\"").dropFirst()
            .compactMap { Double($0.prefix { $0 != "\"" }) }
        #expect(opacities == UntilTheNewIcon.iconOpacities)
        struct Icon: Decodable {
            struct Group: Decodable { let layers: [Layer] }
            struct Layer: Decodable {
                let imageName: String
                let fill: AnyFill?
                enum CodingKeys: String, CodingKey { case imageName = "image-name", fill }
            }
            /// Present or not is all that matters.
            struct AnyFill: Decodable { init(from decoder: Decoder) throws {} }
            let groups: [Group]
        }
        let icon = try JSONDecoder().decode(Icon.self, from: Self.read("App/Resources/AppIcon.icon/icon.json"))
        let circle = try #require(icon.groups.flatMap(\.layers).first { $0.imageName == "circle.svg" })
        #expect(circle.fill == nil, "a layer fill would paint over the SVG's gradient")
    }

    /// The guard cannot pass by reading nothing: an asset one value out of
    /// step fails it.
    @Test func anAssetOutOfStepFails() throws {
        var colorset = String(decoding: try Self.read("App/Resources/Assets.xcassets/AccentColor.colorset/Contents.json"), as: UTF8.self)
        let red = String(format: "\"0x%02X\"", Self.theme.primary.light >> 16 & 0xFF)
        let range = try #require(colorset.range(of: red))
        colorset.replaceSubrange(range, with: "\"0x01\"")
        #expect(try Self.accentColorValues(Data(colorset.utf8)) != Self.expectedAccentColor(Self.theme))

        let svg = String(decoding: try Self.read("App/Resources/Assets.xcassets/LaunchLogo.imageset/LaunchLogo.svg"), as: UTF8.self)
        let first = Self.hex(UntilTheNewIcon.launchLogoStops[0])
        let wrong = svg.replacingOccurrences(of: "#\(first)", with: "#010203", options: .caseInsensitive)
        #expect(Self.svgStops(wrong) != UntilTheNewIcon.launchLogoStops.map(Self.hex))
    }
}

/// The retired accent themes (#1379, #2062): one theme, and nothing stored.
struct RetiredAccentThemesTests {
    @Test func aStoredThemeIsForgotten() throws {
        let defaults = try #require(UserDefaults(suiteName: "retired-themes-\(UUID().uuidString)"))
        defaults.set(["acct-1": "violet"], forKey: "display.accentTheme")
        defaults.set("violet", forKey: "display.accentTheme.lastApplied")
        BrandTheme.forgetRetiredThemes(in: defaults)
        #expect(defaults.object(forKey: "display.accentTheme") == nil)
        #expect(defaults.object(forKey: "display.accentTheme.lastApplied") == nil)
    }
}
