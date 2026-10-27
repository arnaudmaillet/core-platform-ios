import Foundation
import Testing

/// NO PICTURE DRAWN STRAIGHT FROM THE PIPELINE (#1772), `BareImageLoadGuardTests`'
/// sibling: a view that reads `pipeline.image(for:` or `cachedImage(for:` and
/// sets the result itself skips the slot — its bone, its dissolve, its failed
/// ground — as surely as a bare `ImageLoadSlot` did. The 2026-10-27 audit
/// found a dozen such loads the older guard could not see.
///
/// Reading the pipeline is not wrong in itself: a warm-up, a flight's
/// stand-in, a menu's image, a now-playing artwork are not a view's picture.
/// Each file that reads it says why below; a new one uses the slot
/// (`CoverSlot`, `AvatarView`, `ImageContentView`), or argues its case.
///
/// ⚠️ A REPO-WIDE GUARD IN MEDIACORE'S LANE: touching a picture load
/// anywhere, run MediaCore's tests.
struct DirectPipelineReadGuardTests {
    /// File name → why it reads the pipeline directly.
    static let allowed: [String: String] = [
        // The slots themselves.
        "MediaSlot.swift": "the media slot",
        "AvatarView.swift": "the avatar's slot (the animated still's lookup)",
        "ImageContentView.swift": "the plain picture's slot",
        // Not a view's picture.
        "FeedFeatureBuilder.swift": "the launch warm-up of the first post's picture (#1765)",
        "SnapAuthorIdentityView.swift": "warms the next author's face into the pipeline",
        "SnapFeedViewController.swift": "the lock screen's now-playing artwork",
        "ForYouViewController.swift": "a story ring's larger face, handed to a flight",
        "ForYouGridPage.swift": "a flight's stand-in and the landing cover's warm-up",
        "PostShelfSection.swift": "the autoplay's cache probe: is the cover drawn yet",
        "SnapSideListAutoplay.swift": "the autoplay's cache probe",
        "SoundSheetAutoplay.swift": "the autoplay's cache probe",
        "SoundSheetViewController.swift": "the sound's artwork for a flight and the header (follow-up of #1772)",
        "MapsViewController.swift": "a returning flight's cover",
        "ProfileFeatureBuilder.swift": "an account switcher's face, handed to a menu",
        "ProfileSwitcherMenuFactory.swift": "a menu row's image (UIMenu draws no view of ours)",
        // Pictures drawn in a list configuration or a bar pill's blur, not in
        // a view a slot can hold — follow-up of #1772.
        "AuthorizedAppsViewController.swift": "an app icon in a UIListContentConfiguration",
        "RecentlyDeletedViewController.swift": "a post thumbnail in a UIListContentConfiguration",
        "SnapMediaAttributionView.swift": "the sound pill's cover, drawn inside its blur transition",
        "SnapSoundBubble.swift": "the sound bubble's cover, read for the pill's still",
        "MapSubFilterBarView.swift": "a sub-filter's face inside a button configuration",
        "MapSubFilterSheetViewController.swift": "a sub-filter's face inside a button configuration",
    ]

    /// `pipeline.image(for:`, `pipeline?.cachedImage(for:`, `.cachedCover(for:`.
    static let pattern = try! NSRegularExpression(
        pattern: #"[pP]ipeline\??\.(image|cachedImage)\(for:|\.cachedCover\(for:"#
    )

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MediaCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MediaCore
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }

    /// Whether `text` reads a picture straight from the pipeline — outside comments.
    static func readsDirectly(_ text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//") else { return false }
            let string = String(code)
            return pattern.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
        }
    }

    @Test func everyViewDrawsItsPictureThroughTheSlot() {
        var found: Set<String> = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/.build/"), !path.contains("/Tests/") else { continue }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if Self.readsDirectly(text) { found.insert(url.lastPathComponent) }
            }
        }
        let unexplained = found.subtracting(Self.allowed.keys)
        #expect(unexplained.isEmpty, "draw the picture through the slot (CoverSlot, AvatarView, ImageContentView), or argue the case: \(unexplained.sorted())")
        let stale = Set(Self.allowed.keys).subtracting(found)
        #expect(stale.isEmpty, "these no longer read the pipeline directly — drop them: \(stale.sorted())")
    }

    @Test func thePatternFindsTheShape() {
        #expect(Self.readsDirectly("let image = try? await pipeline.image(for: url, size: .px256)"))
        #expect(Self.readsDirectly("if let cached = imagePipeline.cachedImage(for: url) {"))
        #expect(Self.readsDirectly("guard let cached = imagePipeline.cachedCover(for: thumbnail) else {"))
        #expect(!Self.readsDirectly("// pipeline.image(for: url)"))
        #expect(!Self.readsDirectly("OverlayRasterizer.image(for: $0, outputWidth: $1, scale: $2)"))
        #expect(!Self.readsDirectly("cover.load(url, pipeline: pipeline, item: url)"))
    }
}
