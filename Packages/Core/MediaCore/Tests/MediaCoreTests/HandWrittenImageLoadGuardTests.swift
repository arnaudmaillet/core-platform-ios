import Foundation
import Testing

/// NO HAND-WRITTEN "CACHE, THEN A TASK, THEN A DISSOLVE" OUTSIDE THE LADDER
/// (#1085).
///
/// A picture's arrival is the loading ladder's: `ImageContentView`,
/// `ImageLoadSlot` and `RowImageLoads` read the cache first, load otherwise,
/// and run the transition the contract names (`LoadingLadder.Transition`).
/// A file that reads the cache itself AND animates a cross-dissolve is a host
/// writing that rule a second time — the 0.15 / 0.2 / 0.25 / 0.35 s of the
/// survey, each screen its own.
///
/// A match must be on the list below, with its reason: the hero's sources
/// move in #1088 (the media surface, with the hero hooks), the avatars in
/// #943 (the avatar view). A new one goes through the ladder, or argues its
/// case here.
///
/// ⚠️ A REPO-WIDE GUARD IN MEDIACORE'S LANE. A pull request's CI runs only the
/// lanes its diff selects, so a Feed or Profile change that writes the shape
/// again merges green and turns the `develop` backstop red. Touching image
/// loads anywhere, run MediaCore's tests too (as for `UnsizedImageDecodesGuardTests`).
struct HandWrittenImageLoadGuardTests {
    /// File name → why it may stay.
    static let allowed: [String: String] = [
        // The hero's sources and their grids: the media surface (#1088).
        "PostGridCells.swift": "hero source: the row and tile covers (#1088)",
        "MediaCarouselView.swift": "hero source: the carousel's pages (#1088)",
        "ForYouFollowingCardCell.swift": "hero source: the Following card's cover (#1088)",
        "ForYouGridPage.swift": "hero source: the For You grid's covers and its skeleton dissolve (#1088)",
        "ProfileGalleryGridView.swift": "hero source: the profile gallery's covers and its skeleton dissolve (#1088)",
        "SnapMediaAttributionView.swift": "snap chrome: the sound cover swaps inside the attribution's content transition (#1088)",
        // Avatars not yet on `AvatarView` (#943): each draws its face inside
        // a choreography of its own.
        "ProfileHeaderView.swift": "avatar: a px512 face with a .avatar stand-in, and the push waits on it (arePicturesSettled) (#943)",
        "SnapAuthorIdentityView.swift": "avatar: the bar pill's face swaps inside the item's content transition, drawn by CALayer.render (#943)",
        "MapSubFilterBarView.swift": "avatar: the pills' faces are circle-cropped again for their menus (#943)",
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

    /// Whether `text` reads the image cache and animates a cross-dissolve.
    static func isHandWrittenLoad(_ text: String) -> Bool {
        text.contains(".cachedImage(for:") && text.contains("transitionCrossDissolve")
    }

    @Test func noHostWritesItsOwnImageArrival() {
        var found: Set<String> = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/.build/"), !path.contains("/Tests/"),
                      !path.contains("/MediaCore/Sources/MediaCore/Loading/"),
                      url.lastPathComponent != "ImagePipeline.swift" else { continue }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if Self.isHandWrittenLoad(text) { found.insert(url.lastPathComponent) }
            }
        }
        let unexplained = found.subtracting(Self.allowed.keys)
        #expect(unexplained.isEmpty, "load through ImageContentView / ImageLoadSlot, or argue the case: \(unexplained.sorted())")
        let stale = Set(Self.allowed.keys).subtracting(found)
        #expect(stale.isEmpty, "these no longer write their own load — drop them from the list: \(stale.sorted())")
    }

    /// The scan cannot pass by matching nothing.
    @Test func thePatternFindsTheShape() {
        let shape = """
        if let cached = pipeline.cachedImage(for: url) { view.image = cached }
        UIView.transition(with: view, duration: 0.25, options: .transitionCrossDissolve) {}
        """
        #expect(Self.isHandWrittenLoad(shape))
        #expect(!Self.isHandWrittenLoad("pipeline.cachedImage(for: url)"))
    }
}
