import CoreGraphics
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
/// The icon (#2282): one mark (`mark.svg`) drawn twice — in white, and as a
/// mint glass echo — on a solid ground. Icon Composer writes its colours in
/// `icon.json` as `srgb:` or `display-p3:` components, so they are converted
/// to sRGB here before they are compared: the owner's display-p3 ground was
/// `FF2155` in sRGB, not the primary.
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

    static let iconPath = "App/Resources/AppIcon.icon"
    static let launchLogoPath = "App/Resources/Assets.xcassets/LaunchLogo.imageset/LaunchLogo.svg"

    /// How far an icon colour may sit from the theme, in 0–255 units per
    /// sRGB channel: one unit, the rounding of a hex value written as
    /// five-decimal components. The ground is written in sRGB (`FF1358`
    /// exactly). The mint layer is written in display-p3 (0.46658, 0.98557,
    /// 0.80754), which converts to 22.36, 255.00, 203.06 in sRGB — the
    /// mint `16FFCB` (22, 255, 203) within 0.4 — so it meets the same unit.
    static let iconTolerance = 1.0

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

    // MARK: - The icon

    /// `icon.json`, as far as the guard reads it.
    struct Icon: Decodable {
        struct Fill: Decodable { let solid: String? }
        struct Group: Decodable { let layers: [Layer] }
        struct Layer: Decodable {
            let imageName: String
            let name: String
            let fill: Fill?
            let glass: Bool?
            enum CodingKeys: String, CodingKey { case imageName = "image-name", name, fill, glass }
        }
        let fill: Fill?
        let groups: [Group]
    }

    /// An Icon Composer colour (`srgb:r,g,b,a` or `display-p3:r,g,b,a`) in
    /// sRGB, 0–255 per channel, converted through CoreGraphics. Nil for a
    /// colour space the guard does not read (`extended-gray:` …).
    static func sRGBChannels(_ text: String) -> [Double]? {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let name: CFString
        switch parts[0] {
        case "srgb": name = CGColorSpace.sRGB
        case "display-p3": name = CGColorSpace.displayP3
        default: return nil
        }
        let components = parts[1].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard components.count == 4,
              let space = CGColorSpace(name: name), let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let colour = CGColor(colorSpace: space, components: components.map { CGFloat($0) }),
              let converted = colour.converted(to: sRGB, intent: .defaultIntent, options: nil),
              let out = converted.components, out.count >= 3 else { return nil }
        return out.prefix(3).map { Double($0) * 255 }
    }

    /// A hex value's channels, 0–255.
    static func channels(_ hex: UInt32) -> [Double] {
        [Double(hex >> 16 & 0xFF), Double(hex >> 8 & 0xFF), Double(hex & 0xFF)]
    }

    /// Whether `found` is `expected` within `tolerance` units on every
    /// channel.
    static func matches(_ found: [Double]?, _ expected: UInt32, within tolerance: Double) -> Bool {
        guard let found, found.count == 3 else { return false }
        return zip(found, channels(expected)).allSatisfy { abs($0 - $1) <= tolerance }
    }

    static func icon() throws -> Icon {
        try JSONDecoder().decode(Icon.self, from: read("\(iconPath)/icon.json"))
    }

    // MARK: - The launch logo

    /// An SVG's solid fills, first to last, as upper-case hex.
    static func svgFills(_ svg: String) -> [String] {
        svg.components(separatedBy: "fill=\"#").dropFirst().map { String($0.prefix(6)).uppercased() }
    }

    /// What the launch logo must wear, first to last: the mark in the
    /// primary, then its echo in the mint. One SVG for both appearances: the
    /// echo sits on the primary mark, where the mint `16FFCB` stands out
    /// (2.95:1 against `FF1358`) and the deep mint would not (1.13:1), so
    /// the logo keeps the dark mint (`accent.dark`) on the light page too.
    static func expectedLaunchLogoFills(_ theme: BrandTheme) -> [String] {
        [theme.primary.light, theme.accent.dark].map(hex)
    }

    static func hex(_ value: UInt32) -> String { String(format: "%06X", value) }

    // MARK: - Tests

    /// `AccentColor`'s four values are the primary's: light, dark, and the
    /// Increased Contrast pair.
    @Test func theAccentColorIsThePrimary() throws {
        let found = try Self.accentColorValues(
            Self.read("App/Resources/Assets.xcassets/AccentColor.colorset/Contents.json")
        )
        #expect(found == Self.expectedAccentColor(Self.theme))
    }

    /// The icon's ground is the primary, within one unit per channel once
    /// converted to sRGB. The icon has one ground for every appearance, and
    /// the primary is the same in both (`FF1358`).
    @Test func theIconGroundIsThePrimary() throws {
        #expect(Self.theme.primary.light == Self.theme.primary.dark)
        let ground = try #require(try Self.icon().fill?.solid, "the icon's ground is a solid fill")
        let found = Self.sRGBChannels(ground)
        #expect(Self.matches(found, Self.theme.primary.light, within: Self.iconTolerance),
                "the icon's ground \(ground) is \(found ?? []) in sRGB, not the primary \(Self.hex(Self.theme.primary.light))")
    }

    /// The icon's glass layer — the mark's echo — is filled with the mint
    /// (`accent` on dark grounds, the mint itself), within one unit per
    /// channel. Its opacities are the owner's (#2282, problem 1), not
    /// checked here.
    @Test func theIconMintLayerIsTheAccent() throws {
        let layers = try Self.icon().groups.flatMap(\.layers)
        let mint = try #require(layers.first { $0.glass == true }, "the icon has a glass (mint) layer")
        let fill = try #require(mint.fill?.solid, "the mint layer has a solid fill")
        let found = Self.sRGBChannels(fill)
        #expect(Self.matches(found, Self.theme.accent.dark, within: Self.iconTolerance),
                "the mint layer \(fill) is \(found ?? []) in sRGB, not the accent \(Self.hex(Self.theme.accent.dark))")
    }

    /// Both layers draw the one mark, and the bundle holds nothing else.
    @Test func theIconDrawsOneMark() throws {
        let images = Set(try Self.icon().groups.flatMap(\.layers).map(\.imageName))
        #expect(images == ["mark.svg"])
        let assets = try FileManager.default.contentsOfDirectory(
            atPath: Self.root.appendingPathComponent("\(Self.iconPath)/Assets").path
        )
        #expect(assets.filter { !$0.hasPrefix(".") }.sorted() == ["mark.svg"])
    }

    /// The launch logo wears the theme: the mark in the primary, its echo in
    /// the mint.
    @Test func theLaunchLogoWearsTheTheme() throws {
        let svg = String(decoding: try Self.read(Self.launchLogoPath), as: UTF8.self)
        #expect(Self.svgFills(svg) == Self.expectedLaunchLogoFills(Self.theme))
    }

    /// The guard cannot pass by reading nothing: a value a few units out of
    /// step fails each comparison.
    @Test func anAssetOutOfStepFails() throws {
        // The comparison: the primary itself passes; three units off on one
        // channel, or the owner's display-p3 ground (FF2155), does not.
        let primary = Self.theme.primary.light
        #expect(Self.matches(Self.channels(primary), primary, within: Self.iconTolerance))
        var off = Self.channels(primary)
        off[1] += 3
        #expect(!Self.matches(off, primary, within: Self.iconTolerance))
        let p = Self.channels(primary).map { String(format: "%.5f", $0 / 255) }
        #expect(Self.matches(Self.sRGBChannels("srgb:\(p[0]),\(p[1]),\(p[2]),1.00000"), primary, within: Self.iconTolerance))
        #expect(!Self.matches(Self.sRGBChannels("display-p3:0.91790,0.24201,0.35235,1.00000"), primary, within: Self.iconTolerance))
        #expect(!Self.matches(nil, primary, within: Self.iconTolerance))

        var colorset = String(decoding: try Self.read("App/Resources/Assets.xcassets/AccentColor.colorset/Contents.json"), as: UTF8.self)
        let red = String(format: "\"0x%02X\"", Self.theme.primary.light >> 16 & 0xFF)
        let range = try #require(colorset.range(of: red))
        colorset.replaceSubrange(range, with: "\"0x01\"")
        #expect(try Self.accentColorValues(Data(colorset.utf8)) != Self.expectedAccentColor(Self.theme))

        let svg = String(decoding: try Self.read(Self.launchLogoPath), as: UTF8.self)
        let first = Self.expectedLaunchLogoFills(Self.theme)[0]
        let wrong = svg.replacingOccurrences(of: "#\(first)", with: "#010203", options: .caseInsensitive)
        #expect(wrong != svg)
        #expect(Self.svgFills(wrong) != Self.expectedLaunchLogoFills(Self.theme))
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
