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

    /// `AccentColor`'s four values are the primary's: light, dark, and the
    /// Increased Contrast pair.
    @Test func theAccentColorIsThePrimary() throws {
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
        let set = try JSONDecoder().decode(
            Colorset.self, from: Self.read("App/Resources/Assets.xcassets/AccentColor.colorset/Contents.json")
        )
        var found: [String: UInt32] = [:]
        for entry in set.colors {
            let appearances = entry.appearances ?? []
            let dark = appearances.contains { $0.appearance == "luminosity" && $0.value == "dark" }
            let high = appearances.contains { $0.appearance == "contrast" && $0.value == "high" }
            func channel(_ name: String) -> UInt32 {
                let text = entry.color.components[name] ?? ""
                return UInt32(text.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? .max
            }
            let value = channel("red") << 16 | channel("green") << 8 | channel("blue")
            found[(dark ? "dark" : "light") + (high ? "IC" : "")] = value
        }
        let primary = Self.theme.primary
        #expect(found == ["light": primary.light, "dark": primary.dark, "lightIC": primary.lightIC, "darkIC": primary.darkIC])
    }

    /// The launch logo's gradient stops, first to last.
    @Test func theLaunchLogoWearsTheThemesStops() throws {
        let svg = String(decoding: try Self.read("App/Resources/Assets.xcassets/LaunchLogo.imageset/LaunchLogo.svg"), as: UTF8.self)
        let stops = svg.components(separatedBy: "stop-color=\"#").dropFirst().map { String($0.prefix(6)) }
        let expected = Self.theme.launchLogoStops.map { String(format: "%06X", $0) }
        #expect(stops.map { $0.uppercased() } == expected)
    }

    /// The icon's blob fill, exactly as Icon Composer writes it.
    @Test func theIconWearsTheThemesGradient() throws {
        let json = String(decoding: try Self.read("App/Resources/AppIcon.icon/icon.json"), as: UTF8.self)
        for stop in Self.theme.iconGradient {
            #expect(json.contains("\"\(stop)\""), "icon.json has no \(stop)")
        }
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
