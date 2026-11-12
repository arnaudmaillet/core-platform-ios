import Foundation
import Testing

/// One ground for every skeleton (#1753): no host sets a bone's ground by
/// hand. The scan half of DesignSystem's `SkeletonGroundGuardTests` (#2371).
struct SkeletonGroundScanGuardTests {
    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignSystemTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // DesignSystem
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }

    /// Whether `text` sets a bone's ground by hand: a file that builds a
    /// `SkeletonBoneView` and assigns `backgroundColor` to something named
    /// as a bone or a skeleton.
    static func setsBoneGroundByHand(_ text: String) -> Bool {
        guard text.contains("SkeletonBoneView(") else { return false }
        let pattern = #"\b\w*(bone|Bone|skeleton|Skeleton)\w*\??\.backgroundColor\s*="#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    @Test func noHostSetsABonesGroundByHand() {
        var found: Set<String> = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/.build/"), !path.contains("/Tests/"),
                      url.lastPathComponent != "SkeletonBoneView.swift" else { continue }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if Self.setsBoneGroundByHand(text) { found.insert(url.lastPathComponent) }
            }
        }
        #expect(found.isEmpty, "state a bone's ground through SkeletonBoneView(fill:): \(found.sorted())")
    }

    /// The scan cannot pass by matching nothing.
    @Test func thePatternFindsTheShape() {
        #expect(Self.setsBoneGroundByHand("""
        let bone = SkeletonBoneView(rounding: .fixed(0))
        bone.backgroundColor = .clear
        """))
        #expect(!Self.setsBoneGroundByHand("let bone = SkeletonBoneView(rounding: .fixed(0), fill: .clear)"))
    }
}
