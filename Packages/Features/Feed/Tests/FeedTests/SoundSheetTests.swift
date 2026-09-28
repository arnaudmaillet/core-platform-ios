import CoreModels
import FeedInterface
import MediaCore
import Testing
import UIKit
@testable import Feed

/// The sound sheet's rules: how it opens, and that no detent — large
/// included — pauses the clip behind.
@MainActor
struct SoundSheetTests {
    private func sheet(tiles: Int = 1) -> SoundSheetViewController {
        SoundSheetViewController(
            sound: PostSound(
                id: "clip-01", title: "Veridis Quo", artist: "Daft Punk",
                previewURL: nil, artworkURL: nil, duration: 30
            ),
            authorHandle: "ava",
            fallbackArtworkURL: nil,
            tiles: (0..<tiles).map {
                SoundSheetViewController.Tile(
                    postID: PostID("p\($0)"), thumbnailURL: nil, caption: nil, isCurrent: $0 == 0
                )
            },
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
    }

    @Test func itOpensCollapsedWithTwoDetents() throws {
        let controller = sheet()
        let presentation = try #require(controller.sheetPresentationController)
        #expect(presentation.detents.count == 2)
        #expect(presentation.selectedDetentIdentifier?.rawValue == "sound.collapsed")
        #expect(presentation.prefersGrabberVisible)
    }

    /// Large leaves the clip behind playing, and so does coming back down to
    /// collapsed — and collapsed is still there to come back to.
    @Test func largeDoesNotCoverTheClip() throws {
        let controller = sheet()
        let presentation = try #require(controller.sheetPresentationController)
        var covered: [Bool] = []
        controller.onCoverChanged = { covered.append($0) }

        presentation.selectedDetentIdentifier = .large
        controller.sheetPresentationControllerDidChangeSelectedDetentIdentifier(presentation)
        #expect(covered.isEmpty, "the clip behind paused at large")
        #expect(presentation.detents.count == 2, "large must keep collapsed to come back to")

        presentation.selectedDetentIdentifier = presentation.detents.first?.identifier
        controller.sheetPresentationControllerDidChangeSelectedDetentIdentifier(presentation)
        #expect(covered.isEmpty, "a detent change paused or resumed the clip behind")
    }

    /// The collapsed detent leaves the clip playing.
    @Test func collapsedDoesNotCover() throws {
        let controller = sheet()
        let presentation = try #require(controller.sheetPresentationController)
        var covered: [Bool] = []
        controller.onCoverChanged = { covered.append($0) }

        controller.sheetPresentationControllerDidChangeSelectedDetentIdentifier(presentation)

        #expect(covered.isEmpty)
    }

    @Test func theMetaLineIsDurationAndCount() {
        #expect(SoundSheetViewController.meta(duration: 30, posts: 1) == "0:30 · 1 post")
        #expect(SoundSheetViewController.meta(duration: 75.4, posts: 3) == "1:15 · 3 posts")
        #expect(SoundSheetViewController.meta(duration: nil, posts: 2) == "2 posts")
    }
}
