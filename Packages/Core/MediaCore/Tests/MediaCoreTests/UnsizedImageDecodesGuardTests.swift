import Foundation
import Testing

/// NO FULL-SIZE DECODE BY OMISSION (#1086).
///
/// `ImagePipeline.image(for:)` and `cachedImage(for:)` default `size` to
/// `.full` — up to 1200 px — so a forgotten argument compiles and decodes a
/// 40 pt avatar at ~88× the pixels of `.avatar`, filling the decoded-image
/// budget and pushing the feed's real pictures out. #894 sized part of the
/// call sites; the avatar hosts it missed went on decoding at full size.
///
/// This scans the app and every package for a pipeline call with no `size:`.
/// A match must be in a file on the list below, with the reason its pictures
/// are wanted whole: media a viewer fills the screen with, or a cover a hero
/// flies from and lands on at full size. An avatar or a small thumbnail
/// passes its bucket instead.
struct UnsizedImageDecodesGuardTests {
    /// `File.swift` → why its unsized decodes are wanted at full size.
    static let allowed: [String: String] = [
        "MediaCarouselView.swift": "a post's media pages, shown edge to edge",
        "PostGridCells.swift": "grid and card covers: the picture a post's hero flies from",
        "MapsViewController.swift": "the pin cover a marker's hero flies from",
        "MapClusterAnnotationView.swift": "a cluster's cover, the hero source of its gallery",
        "MapAnnotationView.swift": "a pin's cover, the hero source of its post",
        "ProfileGalleryGridView.swift": "gallery covers, the profile grid's hero sources",
        "ForYouRowOrigins.swift": "a row's cover handed to the hero as its origin",
        "ForYouViewController.swift": "the page picture a For You hero lands on",
        "ForYouGridPage.swift": "For You's grid covers and their warm-up, hero sources",
        "ForYouRailsView.swift": "rail covers, hero sources",
        "SnapFeedCell.swift": "the full-screen post and its video poster",
        "SnapFeedViewController.swift": "the lock-screen artwork of the post playing",
        "SoundSheetAutoplay.swift": "sound sheet covers, hero sources",
        "SoundSheetTileCell.swift": "sound sheet covers, hero sources",
        "SoundSheetViewController.swift": "the sound's cover, shown large",
        "PlaceProfileViewController.swift": "the place page's banner, full width",
        "ThreadMediaViewer.swift": "a conversation's media, full screen",
        "ThreadMediaView.swift": "a conversation's media bubble, the viewer's hero source",
        "PostDetailViewController.swift": "the post's media (its avatar is sized)",
        "WalletClaimViews.swift": "a stake row's post cover, the hero source of the post it opens",
    ]

    /// A pipeline receiver, then `image(for: x)` or `cachedImage(for: x)`
    /// closed with no further argument.
    static let pattern = try! NSRegularExpression(
        pattern: #"[Pp]ipeline\??\.(?:cachedImage|image)\(for:\s*[^,()]+\)"#
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

    /// `File.swift:line` of every unsized call in `text`.
    static func matches(in text: String, file: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            guard let found = Range(match.range, in: text) else { return nil }
            let line = text[..<found.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            return "\(file):\(line)"
        }
    }

    @Test func everySmallImageNamesItsBucket() {
        var unexplained: [String] = []
        var seenAllowed: Set<String> = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/.build/"), !path.contains("/Tests/"),
                      url.lastPathComponent != "ImagePipeline.swift" else { continue }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let found = Self.matches(in: text, file: url.lastPathComponent)
                guard !found.isEmpty else { continue }
                if Self.allowed[url.lastPathComponent] != nil {
                    seenAllowed.insert(url.lastPathComponent)
                } else {
                    unexplained += found
                }
            }
        }
        #expect(unexplained.isEmpty, """
            Decoded at full size (1200 px) by omission: \(unexplained.sorted()). Pass `size: .avatar` \
            (or the bucket the view draws at); a picture wanted whole goes on `allowed` with its reason.
            """)
        // A file that no longer decodes unsized leaves the list.
        #expect(Set(Self.allowed.keys).subtracting(seenAllowed).isEmpty,
                "stale entries: \(Set(Self.allowed.keys).subtracting(seenAllowed).sorted())")
    }

    /// The scan sees an unsized call and lets a sized one through.
    @Test func thePatternTellsSizedFromUnsized() {
        let text = """
            let a = try await imagePipeline.image(for: url)
            let b = pipeline.cachedImage(for: url, size: .avatar)
            let c = self?.imagePipeline.image(for: avatar)
            let d = FlagPalette.image(for: country.code)
            """
        #expect(Self.matches(in: text, file: "X.swift") == ["X.swift:1", "X.swift:3"])
    }
}
