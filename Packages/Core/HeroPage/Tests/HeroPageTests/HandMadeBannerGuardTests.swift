import Foundation
import Testing

/// NO HAND-MADE BANNER OUTSIDE `HeroBannerView` (#1752).
///
/// A banner is drawn by `HeroBannerView`, through `HeroHeaderView`: the
/// picture on the loading ladder (its skeleton while it loads, the neutral
/// backdrop on a failure), the video over it. A surface that builds a
/// banner's picture itself, or loads a banner URL into an image view of its
/// own, decides again what a loading banner looks like — a flat card, a
/// spinner, nothing — which is what the audit of 2026-10-26 set out to end.
///
/// ⚠️ A REPO-WIDE GUARD IN HEROPAGE'S LANE. A pull request's CI runs only the
/// lanes its diff selects: touching a banner anywhere, run HeroPage's tests.
struct HandMadeBannerGuardTests {
    /// File name → why it may build a banner's parts.
    static let allowed: [String: String] = [
        "HeroBannerView.swift": "the banner itself",
        "HeroHeaderView.swift": "the one host of the banner view",
    ]

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // HeroPageTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // HeroPage
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }

    /// Whether `text` builds a banner by hand: a banner picture or banner
    /// view of its own, or a banner URL fed STRAIGHT to the image pipeline
    /// (`image(for:)`, `cachedImage(for:)`, a slot's `load(`).
    ///
    /// ⚠️ THE URL MUST BE THE LOAD'S ARGUMENT, not merely in the same file
    /// (the merge coordinator, 2026-10-27): a file that passes a banner URL
    /// along and loads some other picture is no banner load, and a
    /// file-level match would turn develop red for it.
    static func buildsBanner(_ text: String) -> Bool {
        if text.contains("HeroBannerPictureView(") || text.contains("HeroBannerView(") { return true }
        let pattern = #"(\.image\(for:|cachedImage\(for:|\.load\()\s*[\w.?!]*banner(Image)?URL"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    @Test func noSurfaceBuildsItsOwnBanner() {
        var found: Set<String> = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/.build/"), !path.contains("/Tests/"),
                      // The picture's own definition.
                      url.lastPathComponent != "HeroBannerFade.swift"
                else { continue }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if Self.buildsBanner(text) { found.insert(url.lastPathComponent) }
            }
        }
        let unexplained = found.subtracting(Self.allowed.keys)
        #expect(unexplained.isEmpty, "draw the banner with HeroBannerView (HeroHeaderView), or argue the case: \(unexplained.sorted())")
        let stale = Set(Self.allowed.keys).subtracting(found)
        #expect(stale.isEmpty, "these no longer build a banner — drop them from the list: \(stale.sorted())")
    }

    /// The scan cannot pass by matching nothing.
    @Test func thePatternFindsTheShape() {
        #expect(Self.buildsBanner("let banner = HeroBannerView(imagePipeline: pipeline)"))
        #expect(Self.buildsBanner("let image = try await pipeline.image(for: profile.bannerImageURL, size: .full)"))
        #expect(Self.buildsBanner("load.load(model.bannerImageURL, using: pipeline) { _, _ in }"))
        // A URL passed along is not a load.
        #expect(!Self.buildsBanner("content.bannerImageURL = profile.bannerURL"))
        // Nor is another picture loaded in a file that mentions a banner.
        #expect(!Self.buildsBanner("""
        content.bannerImageURL = profile.bannerURL
        let face = try await pipeline.image(for: profile.avatarURL, size: .avatar)
        """))
    }
}
