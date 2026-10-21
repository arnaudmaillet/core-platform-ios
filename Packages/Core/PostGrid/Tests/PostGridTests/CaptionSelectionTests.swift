import CoreModels
import Foundation
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// Select Text on a list card's caption (#1498 §4): in place, the caption
/// whole, never its "… Show more"; none on a card that cuts its own tail.
@MainActor
struct CaptionSelectionTests {
    private static let long = String(repeating: "A long post that goes on and on about nothing much. ", count: 10)
    private static let width: CGFloat = 322
    private static let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())

    private static func card(caption: String, lines: Int? = nil) -> PostGridListRowCell {
        let post = GalleryPost(
            id: PostID("post-1"), kind: .text, isRepost: false, thumbnailURL: nil,
            caption: caption, publishedAtMS: 0,
            authorID: ProfileID("ada"), authorName: "Ada Lovelace", authorHandle: "ada"
        )
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: width, height: 600))
        cell.configure(with: post, imagePipeline: pipeline, captionLines: lines)
        cell.layoutIfNeeded()
        return cell
    }

    /// A truncated caption is revealed first, then selected whole: the
    /// selection's text is the caption, with no "Show more" in it.
    @Test func aTruncatedCaptionIsRevealedThenSelectedWhole() throws {
        let cell = Self.card(caption: Self.long)
        #expect(cell.canSelectCaption)
        cell.beginCaptionSelection()
        #expect(cell.isSelectingCaption)
        #expect(cell.debugCaptionText == Self.long, "the caption was not revealed whole")
        #expect(cell.debugCaptionText?.contains("Show more") == false)

        cell.endCaptionSelection()
        #expect(!cell.isSelectingCaption)
    }

    /// Reuse ends a selection: it belongs to the post it was made on.
    @Test func reuseEndsTheSelection() {
        let cell = Self.card(caption: "Third coffee.")
        cell.beginCaptionSelection()
        #expect(cell.isSelectingCaption)
        cell.prepareForReuse()
        #expect(!cell.isSelectingCaption)
    }

    /// No caption, or a card held to fixed lines (the shelf's text cards):
    /// nothing to select in place.
    @Test func nothingToSelectWithoutAWholeCaption() {
        #expect(!Self.card(caption: "  ").canSelectCaption)
        #expect(!Self.card(caption: Self.long, lines: 2).canSelectCaption)
    }
}
