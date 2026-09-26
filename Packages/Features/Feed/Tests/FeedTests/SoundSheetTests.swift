import CoreModels
import FeedInterface
import MediaCore
import Testing
import UIKit
@testable import Feed

/// The sound sheet's rules: how it opens, what large means for the clip
/// behind, and that from large a drag down can only close it.
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

    /// Large covers the clip behind; coming back down to collapsed gives it
    /// back — and collapsed is still there to come back to.
    @Test func largeCoversAndCollapsedGivesTheClipBack() throws {
        let controller = sheet()
        let presentation = try #require(controller.sheetPresentationController)
        var covered: [Bool] = []
        controller.onCoverChanged = { covered.append($0) }

        presentation.selectedDetentIdentifier = .large
        controller.sheetPresentationControllerDidChangeSelectedDetentIdentifier(presentation)
        #expect(covered == [true], "the clip behind did not pause at large")
        #expect(presentation.detents.count == 2, "large must keep collapsed to come back to")

        presentation.selectedDetentIdentifier = presentation.detents.first?.identifier
        controller.sheetPresentationControllerDidChangeSelectedDetentIdentifier(presentation)
        #expect(covered == [true, false], "back at collapsed, the clip did not play again")
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
