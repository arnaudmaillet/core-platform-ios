import Foundation
import Testing

/// ⚠️ A REPO-WIDE GUARD (#1657), like DesignSystem's `RawHueGuardTests`: the
/// hero page's mechanics — the header's travel and fade, the dock line, the
/// pages' alignment and detents, the banner's picture and ramp, the pull's
/// indicator — live in `Packages/Core/HeroPage`, and a screen that wants them
/// subclasses `HeroPageViewController` rather than copying them.
///
/// The place page held a copy of the profile's arithmetic for a year, and the
/// two drifted (#1651). This scans every source file under `App/` and
/// `Packages/` (tests excluded, HeroPage itself excluded) for the shapes
/// those copies took. A file may keep one only with a reason on the list
/// below.
///
/// CI only runs this in HeroPage's lane, which a change elsewhere does not
/// select: the full run on `develop` is what catches a copy landing in a
/// feature.
struct HeroPageArithmeticGuardTests {
    /// File name → why its shape stays.
    /// None today: the primitives' own files (DesignSystem's
    /// `HeaderIdentityFade`, `HeroBannerPictureView`…) define them without
    /// calling them.
    static let allowed: [String: String] = [:]

    /// What a copy of the hero page's mechanics looks like.
    static let patterns = [
        // The identity fade and the scroll coordinator.
        "HeaderIdentityFade.alpha(", "HeroScrollCoordinator(", "func identityAlpha(",
        // The pager's rules.
        "func alignedOffset(", "func snapDetents(",
        // The banner's machinery and the pull's indicator.
        "HeroBannerPictureView(", "HeroBannerRampView(", "HeroPullToRefreshView(",
        // The place page's hosted-page contract (the pager's now).
        "protocol PlaceProfileHostedPage",
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

    /// Whether `text` copies a piece of the hero page's mechanics.
    static func copiesHeroMechanics(_ text: String) -> Bool {
        patterns.contains { text.contains($0) }
    }

    @Test func theShapesAreRecognised() {
        #expect(Self.copiesHeroMechanics("let alpha = HeaderIdentityFade.alpha(travelled: t, dockLine: d)"))
        #expect(Self.copiesHeroMechanics("private let bannerView = HeroBannerPictureView()"))
        #expect(Self.copiesHeroMechanics("static func alignedOffset(current: CGFloat) -> CGFloat"))
        #expect(!Self.copiesHeroMechanics("heroPager.setSnapDetents(scroll.detents(notch: nil))"))
    }

    @Test func noFeatureCopiesTheHeroPagesMechanics() {
        var found: Set<String> = []
        var used: Set<String> = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift",
                      !path.contains("/Tests/"), !path.contains("/.build/"),
                      !path.contains("/Packages/Core/HeroPage/"),
                      let text = try? String(contentsOf: url, encoding: .utf8),
                      Self.copiesHeroMechanics(text)
                else { continue }
                let name = url.lastPathComponent
                if Self.allowed[name] != nil {
                    used.insert(name)
                } else {
                    found.insert(path.replacingOccurrences(of: Self.root.path + "/", with: ""))
                }
            }
        }
        #expect(found.isEmpty, "hero page mechanics copied outside HeroPage — subclass HeroPageViewController: \(found.sorted())")
        let stale = Set(Self.allowed.keys).subtracting(used)
        #expect(stale.isEmpty, "allow-list entries with nothing to allow: \(stale.sorted())")
    }
}
