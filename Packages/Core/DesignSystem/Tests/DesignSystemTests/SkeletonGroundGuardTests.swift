import Foundation
import Testing
import UIKit
@testable import DesignSystem

/// ONE GROUND FOR EVERY SKELETON (#1753): `SkeletonBoneView` fills with
/// `Surface.skeleton`, an opaque neutral grey, unless its host states another
/// through `fill`. A raw `backgroundColor` on a bone is a host deciding the
/// ground on its own again — the translucent fill that read grey on a page
/// and black over a banner (the owner, 2026-10-27).
///
/// ⚠️ A REPO-WIDE GUARD IN DESIGNSYSTEM'S LANE: touching a skeleton anywhere,
/// run DesignSystem's tests.
@MainActor
struct SkeletonGroundGuardTests {
    @Test func aBoneWearsTheOpaqueGreyByDefault() {
        let bone = SkeletonBoneView()
        #expect(bone.fill == Surface.skeleton)
        #expect(bone.backgroundColor == Surface.skeleton)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let resolved = Surface.skeleton.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            var alpha: CGFloat = 0
            resolved.getWhite(nil, alpha: &alpha)
            #expect(alpha == 1, "the skeleton's ground must be opaque in \(style == .dark ? "dark" : "light")")
        }
    }

    @Test func aHostOverridesTheGroundThroughFill() {
        let bone = SkeletonBoneView(rounding: .fixed(0), fill: .clear)
        #expect(bone.backgroundColor == .clear)
        bone.fill = .systemGray3
        #expect(bone.backgroundColor == .systemGray3)
    }

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
