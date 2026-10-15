import DesignSystem
import Foundation
import Testing

/// ⚠️ THE FULL-SCREEN POST DRAWS THE APP'S OWN ICONS (#1184): every glyph on
/// the snap screen and in its comments layout comes from the custom set
/// (`AppSymbol`), the owner's call. The exceptions are the top bar's back
/// chevron and the comments' close cross, which stay the system's, and two
/// non-icons: the follow badge's disc (a shape) and a DEBUG stand-in picture.
///
/// It scans the sources for a native symbol name — a `systemName:` string
/// literal — so a new native icon fails here instead of shipping a mix.
struct FullScreenCustomIconsTests {
    static let allowed: Set<String> = [
        "chevron.backward", // the top bar's back
        "xmark", // the comments layout's close
        "circle.fill", // the follow badge's disc: a shape, not an icon
        "photo", // a DEBUG stand-in picture
    ]

    private static var feedSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // FeedTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Feed
            .appendingPathComponent("Sources/Feed")
    }

    @Test func theScreenNamesNoNativeIcon() throws {
        let literal = try Regex(#"systemName:\s*"([^"]+)""#)
        var found: [String] = []
        for folder in ["Snap", "Comments"] {
            let enumerator = FileManager.default.enumerator(
                at: Self.feedSources.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                // The sound sheet is a screen of its own.
                guard url.pathExtension == "swift", !url.path.contains("/Snap/Sound/") else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                for match in text.matches(of: literal) {
                    let name = String(match.output[1].substring ?? "")
                    if !Self.allowed.contains(name) { found.append("\(url.lastPathComponent): \(name)") }
                }
            }
        }
        #expect(found.isEmpty, "a native icon on the full-screen post: \(found)")
    }

    /// The scan cannot pass by finding nothing: the back chevron is there.
    @Test func theScanSeesTheBackChevron() throws {
        let file = Self.feedSources.appendingPathComponent("Snap/SnapAuthorIdentityView.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains(#"systemName: "chevron.backward""#))
    }

    /// Every custom glyph the screen reads resolves to an image.
    @Test(arguments: [
        AppSymbol.sort, .notInterested, .flag, .plus, .check, .checkCircle, .xCircle, .people,
        .peopleFilled, .clock, .musicNote, .speakerSlash, .speakerSlashFilled, .hand, .warning,
        .warningCircleFilled, .caretDown, .caretUp, .sendFilled, .waveform, .globe, .pin, .pinFilled, .smiley, .keyboard,
    ])
    func everyNewGlyphResolves(_ symbol: AppSymbol) {
        #expect(symbol.image() != nil, "\(symbol.rawValue) is not in the catalog")
    }
}
