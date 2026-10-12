import Foundation
import Testing

/// NO IMAGE CACHE OUTSIDE THE PIPELINE (#894).
///
/// Fetched images live in `ImagePipeline` (on CacheKit: byte budgets, trims,
/// logout, Settings → Storage), and the other kept pictures in a CacheKit
/// `MemoryCache` (the UI assets class, the editor's overlay pictures). An
/// `NSCache` or a dictionary of images beside them answers to none of that:
/// the author pill's faces, the attribution's covers and the map pills' avatars
/// all were, until #894 moved them.
///
/// This scans the app and every package for the shapes such a cache takes. A
/// match must be on the list below, with the reason it is not a cache of
/// fetched images: a picture still being shown or sent, a drawing memo that
/// lives exactly as long as its view or its source picture, a local inside one
/// function. A new one goes through the pipeline, or argues its case here.
struct ImageCachesOutsidePipelineGuardTests {
    /// `File.swift:name` → why it may stay.
    static let allowed: [String: String] = [
        // Per-view state, freed with its view.
        "LiveMediaBackdrop.swift:ready": "bands of video frames decoded for the next frames on screen, dropped as they show",
        "MediaTimelineTrackView.swift:decoded": "the editor's own timeline frames of the clip being edited",
        "NewPostViewController.swift:clipSheets": "the composer's sampled frames of the picked clips (budgeted in place)",
        "ConversationViewModel.swift:localPreviews": "the pictures the viewer just sent, drawn until the upload lands",
        "CountryShopViewController.swift:flags": "emoji glyphs drawn for the shop's rows (a UI asset), freed with the screen",
        "MapSubFilterBarView.swift:headerImageCache": "circle crops drawn from the pipeline's avatars for the pill menus",
        "DebugMediaLibrary.swift:videoPosters": "DEBUG only: the fake photo library's posters",
        // Locals inside one function.
        "VideoFilmstrip.swift:byRequest": "a local: frames gathered for one filmstrip request",
        "MediaEditorEffectsMode.swift:pictures": "a local: the effect previews of one render pass",
        "HeroBannerFade.swift:sources": "a local: the source images of one fade bake",
        // Memos keyed weakly by the picture they were drawn from.
        "MediaFraming.swift:cache": "blurred 40 px backdrops, held only while their picture lives",
    ]

    /// `NSCache<`, `NSMapTable<UIImage, UIImage>`, and a `var`/`let` typed or
    /// initialised as a dictionary whose values are images (or arrays of them).
    static var patterns: [NSRegularExpression] { [
        #"(?:var|let)\s+(\w+)\b[^\n=]*=\s*NSCache<"#,
        #"(?:var|let)\s+(\w+)\s*:\s*NSCache<"#,
        #"(?:var|let)\s+(\w+)\b[^\n]*NSMapTable<\s*UIImage\s*,\s*UIImage\s*>"#,
        #"(?:var|let)\s+(\w+)\s*:\s*\[[^\]\[:]+:\s*\[?\s*(?:UIImage|CGImage)\s*\]?\s*\]"#,
        #"(?:var|let)\s+(\w+)\s*=\s*\[[^\]\[:]+:\s*\[?\s*(?:UIImage|CGImage)\s*\]?\s*\]\(\)"#,
    ].map { try! NSRegularExpression(pattern: $0) } }

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MediaCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MediaCore
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }

    /// Every `File.swift:name` the patterns find in `text`.
    static func matches(in text: String, file: String) -> Set<String> {
        var found: Set<String> = []
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            for match in pattern.matches(in: text, range: range) {
                guard let name = Range(match.range(at: 1), in: text) else { continue }
                found.insert("\(file):\(text[name])")
            }
        }
        return found
    }

    @Test func noImageCacheLivesOutsideThePipeline() {
        var found: Set<String> = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/.build/"), !path.contains("/Tests/"),
                      !path.contains("/CacheKit/"), url.lastPathComponent != "ImagePipeline.swift" else { continue }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                found.formUnion(Self.matches(in: text, file: url.lastPathComponent))
            }
        }
        let offenders = found.subtracting(Self.allowed.keys).sorted()
        #expect(offenders.isEmpty, "image caches outside the pipeline: \(offenders) — move them onto ImagePipeline or CacheKit, or justify them in `allowed`")
        // A listed entry that no longer matches is a stale excuse.
        let stale = Set(Self.allowed.keys).subtracting(found).sorted()
        #expect(stale.isEmpty, "allowed entries that no longer exist: \(stale)")
    }

    /// The patterns catch the shapes the moved caches had, so the scan cannot
    /// pass by matching nothing.
    @Test func thePatternsCatchTheCachesThatWereMoved() {
        let samples = """
            private static var faces: [URL: UIImage] = [:]
            private var avatarCache: [ProfileID: UIImage] = [:]
            nonisolated(unsafe) private static let stills = NSCache<NSString, UIImage>()
            private static let cache: NSCache<UIImage, UIImage> = {
            private var sheets: [String: [UIImage]] = [:]
            var covers = [URL: UIImage]()
            """
        #expect(Self.matches(in: samples, file: "S.swift") == [
            "S.swift:faces", "S.swift:avatarCache", "S.swift:stills", "S.swift:cache", "S.swift:sheets", "S.swift:covers",
        ])
        #expect(Self.matches(in: "let cache: MemoryCache<String, UIImage> = make()", file: "S.swift").isEmpty,
                "a CacheKit cache is not an offender")
    }
}
