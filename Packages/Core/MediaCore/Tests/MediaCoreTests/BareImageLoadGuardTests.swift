import Foundation
import Testing

/// NO BARE PICTURE LOAD OUTSIDE THE MEDIA SLOT (#1505).
///
/// A remote picture is drawn on `MediaSlot` — through `CoverSlot`,
/// `MediaSurface`, `AvatarView`, `HeroBannerView` or `ImageContentView` — so
/// it shows the skeleton while it is late and arrives with the ladder's
/// dissolve. A file that holds a bare `ImageLoadSlot` (or `RowImageLoads`)
/// decides on its own what a loading picture looks like again: the flat
/// fill and the snap of the owner's recordings (2026-10-21).
///
/// The list held every surface still loading bare while #1505 moved them
/// onto the slot, one step at a time; it is down to the slot itself. A new
/// one uses the slot, or argues its case here.
///
/// ⚠️ A REPO-WIDE GUARD IN MEDIACORE'S LANE. A pull request's CI runs only the
/// lanes its diff selects: touching a picture load anywhere, run MediaCore's
/// tests.
struct BareImageLoadGuardTests {
    /// File name → why it may load a picture bare.
    static let allowed: [String: String] = [
        "MediaSlot.swift": "the media slot itself",
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

    /// Whether `text` holds a bare picture load.
    static func loadsBare(_ text: String) -> Bool {
        text.contains("ImageLoadSlot(") || text.contains("RowImageLoads(")
    }

    @Test func everyPictureLoadsOnTheMediaSlot() {
        var found: Set<String> = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/.build/"), !path.contains("/Tests/") else { continue }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if Self.loadsBare(text) { found.insert(url.lastPathComponent) }
            }
        }
        let unexplained = found.subtracting(Self.allowed.keys)
        #expect(unexplained.isEmpty, "load the picture on MediaSlot (CoverSlot, AvatarView, ImageContentView…), or argue the case: \(unexplained.sorted())")
        let stale = Set(Self.allowed.keys).subtracting(found)
        #expect(stale.isEmpty, "these no longer load bare — drop them from the list: \(stale.sorted())")
    }

    /// The scan cannot pass by matching nothing.
    @Test func thePatternFindsTheShape() {
        #expect(Self.loadsBare("private let load = ImageLoadSlot(size: .full)"))
        #expect(Self.loadsBare("private let loads = RowImageLoads(size: .avatar)"))
        #expect(!Self.loadsBare("private let cover = CoverSlot(view: imageView, size: .px256)"))
    }
}
