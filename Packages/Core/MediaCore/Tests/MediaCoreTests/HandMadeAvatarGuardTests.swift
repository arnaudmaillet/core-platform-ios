import Foundation
import Testing

/// NO HAND-MADE AVATAR OUTSIDE `AvatarView` (#1750).
///
/// A person's face is drawn by the app's avatar: the picture, its skeleton
/// while it loads, the initials without one (the avatar contract). A file
/// that builds the parts itself — an `AvatarImageView` or a
/// `MonogramAvatarView` — is a surface deciding on its own what a loading
/// avatar looks like again: initials first then a cut, a grey disc, a white
/// wash, a person glyph (the audit of 2026-10-26 found all four).
///
/// A match must be on the list below, with its reason. A new one uses
/// `AvatarView` (or `PersonListCell.avatar`), or argues its case here.
///
/// ⚠️ A REPO-WIDE GUARD IN MEDIACORE'S LANE. A pull request's CI runs only the
/// lanes its diff selects: touching an avatar anywhere, run MediaCore's tests.
struct HandMadeAvatarGuardTests {
    /// File name → why it may build an avatar's parts itself.
    static let allowed: [String: String] = [
        "AvatarView.swift": "the app's avatar itself",
        "MonogramAccessoryHost.swift": "DesignSystem's row disc: a symbol row's glyph disc, and the slot AvatarView is installed in",
        "SnapMediaAttributionView.swift": "a sound's cover in an avatar-shaped slot, not a person's face",
    ]

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MediaCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MediaCore
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }

    /// Whether `text` builds an avatar's parts by hand.
    static func buildsAvatarParts(_ text: String) -> Bool {
        text.contains("AvatarImageView()") || text.contains("MonogramAvatarView(")
    }

    @Test func noSurfaceBuildsItsOwnAvatar() {
        var found: Set<String> = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/.build/"), !path.contains("/Tests/"),
                      // The parts' own definitions.
                      !["AvatarImageView.swift", "MonogramAvatarView.swift"].contains(url.lastPathComponent)
                else { continue }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if Self.buildsAvatarParts(text) { found.insert(url.lastPathComponent) }
            }
        }
        let unexplained = found.subtracting(Self.allowed.keys)
        #expect(unexplained.isEmpty, "draw the face with AvatarView, or argue the case: \(unexplained.sorted())")
        let stale = Set(Self.allowed.keys).subtracting(found)
        #expect(stale.isEmpty, "these no longer build an avatar — drop them from the list: \(stale.sorted())")
    }

    /// The scan cannot pass by matching nothing.
    @Test func thePatternFindsTheShape() {
        #expect(Self.buildsAvatarParts("private let face = AvatarImageView()"))
        #expect(Self.buildsAvatarParts("let disc = MonogramAvatarView(diameter: 32)"))
        #expect(!Self.buildsAvatarParts("let avatar = AvatarView(diameter: 32, size: .avatar)"))
        // A static helper is not a disc.
        #expect(!Self.buildsAvatarParts("MonogramAvatarView.monogram(name: name, handle: handle)"))
    }
}
