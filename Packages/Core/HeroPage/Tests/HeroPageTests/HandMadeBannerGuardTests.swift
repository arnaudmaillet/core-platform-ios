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
    /// view of its own, or a banner URL fed to the image pipeline itself.
    static func buildsBanner(_ text: String) -> Bool {
        if text.contains("HeroBannerPictureView(") || text.contains("HeroBannerView(") { return true }
        let readsBannerURL = text.contains("bannerImageURL") || text.contains("bannerURL")
        let loads = text.contains(".image(for:") || text.contains("cachedImage(for:") || text.contains("ImageLoadSlot(")
        return readsBannerURL && loads
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
        #expect(Self.buildsBanner("""
        let url = profile.bannerImageURL
        let image = try await pipeline.image(for: url, size: .full)
        """))
        // A URL passed along is not a load.
        #expect(!Self.buildsBanner("content.bannerImageURL = profile.bannerURL"))
    }
}
