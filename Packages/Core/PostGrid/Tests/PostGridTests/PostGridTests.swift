import CoreModels
import MediaCore
import UIKit
import Foundation
import Testing
@testable import PostGrid

// The profile gallery's own suites (GalleryFilterTests, PostMetadataTests,
// ProfileGalleryTests) still exercise this package's model through Profile —
// they are the proof the extraction changed no behaviour. What lives here is
// the seams the extraction ADDED: the preference key namespace, and the format
// axis used on its own by a surface that resolves its corpus differently.

private func tile(
    _ id: String,
    kind: GalleryPost.Kind,
    isRepost: Bool = false,
    publishedAtMS: Int64 = 0
) -> GalleryPost {
    GalleryPost(
        id: PostID(id),
        kind: kind,
        isRepost: isRepost,
        thumbnailURL: nil,
        caption: "caption \(id)",
        publishedAtMS: publishedAtMS
    )
}

private let posts: [GalleryPost] = [
    tile("photo", kind: .photo, publishedAtMS: 30),
    tile("video", kind: .video, publishedAtMS: 20),
    tile("text", kind: .text, publishedAtMS: 10)
]

struct GalleryPreferencesNamespaceTests {
    /// The default prefix is the profile gallery's original pair. Load-bearing:
    /// it is what installed apps have already written, and what the
    /// `-profile.gallery.format <value>` launch argument addresses.
    @Test func defaultPrefixKeepsTheProfileGalleryKeys() {
        let suiteName = "postgrid-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        GalleryPreferences(defaults: defaults).filter = GalleryFilter(format: .media, source: .reposts)

        #expect(defaults.string(forKey: "profile.gallery.format") == "media")
        #expect(defaults.string(forKey: "profile.gallery.source") == "reposts")
    }

    /// Two surfaces must not yank each other's landing tab.
    @Test func distinctPrefixesDoNotSeeEachOther() {
        let suiteName = "postgrid-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profile = GalleryPreferences(defaults: defaults)
        let discovery = GalleryPreferences(defaults: defaults, keyPrefix: "foryou.gallery")

        profile.filter = GalleryFilter(format: .media, source: .reposts)

        // The second surface is still at its own default, not the first's.
        #expect(discovery.filter == GalleryFilter())

        discovery.filter = GalleryFilter(format: .short, source: .tagged)
        #expect(profile.filter == GalleryFilter(format: .media, source: .reposts))
        #expect(discovery.filter == GalleryFilter(format: .short, source: .tagged))
    }

    /// A value the current build doesn't know degrades to the default rather
    /// than crashing a downgrade — and does so per key, not per store.
    @Test func unknownStoredValuesDegradeToDefaults() {
        let suiteName = "postgrid-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("hologram", forKey: "profile.gallery.format")
        defaults.set("posts", forKey: "profile.gallery.source")

        #expect(GalleryPreferences(defaults: defaults).filter == GalleryFilter(format: .activity, source: .posts))
    }
}

struct GalleryFormatAxisTests {
    @Test func formatFiltersByKind() {
        #expect(GalleryFilter.Format.activity.filtering(posts).map(\.id.rawValue) == ["photo", "video", "text"])
        #expect(GalleryFilter.Format.media.filtering(posts).map(\.id.rawValue) == ["photo", "video"])
        #expect(GalleryFilter.Format.short.filtering(posts).map(\.id.rawValue) == ["text"])
    }

    /// `tiles(authored:tagged:)` must stay exactly "resolve the source, then
    /// apply the format" — the extracted axis is the same pass, not a second
    /// implementation that can drift.
    @Test func tilesAgreesWithTheStandaloneFormatAxis() {
        for format in GalleryFilter.Format.allCases {
            for source in GalleryFilter.Source.allCases {
                let filter = GalleryFilter(format: format, source: source)
                let viaTiles = filter.tiles(authored: posts, tagged: [])
                let viaAxis = format.filtering(
                    GalleryFilter(format: .activity, source: source).tiles(authored: posts, tagged: [])
                )
                #expect(viaTiles == viaAxis, "format \(format) / source \(source)")
            }
        }
    }
}

struct PostGridCountTests {
    @Test func abbreviatesCounts() {
        #expect(PostGridCount.abbreviate(0) == "0")
        #expect(PostGridCount.abbreviate(999) == "999")
        #expect(PostGridCount.abbreviate(1_000) == "1K")
        #expect(PostGridCount.abbreviate(1_234) == "1.2K")
        #expect(PostGridCount.abbreviate(12_500) == "12.5K")
        #expect(PostGridCount.abbreviate(1_500_000) == "1.5M")
    }
}

// MARK: - Hero concealment

/// CONCEAL EXACTLY WHAT THE FLIGHT REPRODUCES.
///
/// A tile is its media edge to edge, so a flight departing one hides the whole
/// cell. A ROW is a card of which the media is one part, and the flight
/// carries only that part — so hiding the whole row removed the caption,
/// author line and metrics that nothing in the air stood in for. They were
/// absent for the length of the flight and snapped back on its last frame,
/// reported as "the rest of the post pops in at the end".
@MainActor
struct ListRowHeroConcealmentTests {
    private func row(kind: GalleryPost.Kind = .photo) -> PostGridListRowCell {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: 390, height: 320))
        cell.configure(with: tile("p", kind: kind),
                       imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
        cell.layoutIfNeeded()
        return cell
    }

    @Test func concealingTheMediaLeavesTheRestOfTheRowVisible() {
        let cell = row()
        cell.setHeroMediaConcealed(true)

        // The cell itself must stay on screen — everything that is NOT the
        // media is what the viewer keeps looking at during the flight.
        #expect(cell.isHidden == false)
        #expect(cell.alpha == 1)
    }

    /// The reason it is alpha and not `isHidden`: a hidden preview reports no
    /// `mediaHeroRect`, and that rect is what the DISMISSAL flies home to. Hide
    /// it and the return leg loses its own landing target mid-flight.
    @Test func aConcealedRowStillReportsWhereItsMediaIs() {
        let cell = row()
        let restingRect = cell.mediaHeroRect
        #expect(restingRect != nil)

        cell.setHeroMediaConcealed(true)

        #expect(cell.mediaHeroRect == restingRect)
    }

    @Test func unconcealingRestoresThePreview() {
        let cell = row()
        cell.setHeroMediaConcealed(true)
        cell.setHeroMediaConcealed(false)

        #expect(cell.mediaHeroRect != nil)
        #expect(cell.isHidden == false)
    }

    /// A text-only row has no media to conceal, and asking must not be an
    /// error — the page applies concealment without knowing the post's kind.
    @Test func aTextRowHasNothingToConcealAndSaysSo() {
        let cell = row(kind: .text)
        #expect(cell.mediaHeroRect == nil)

        cell.setHeroMediaConcealed(true)

        #expect(cell.isHidden == false)
        #expect(cell.mediaHeroRect == nil)
    }
}
