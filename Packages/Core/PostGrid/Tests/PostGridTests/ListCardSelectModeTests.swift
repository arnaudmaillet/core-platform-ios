import CoreModels
import DesignSystem
import Foundation
import MediaCore
import MediaCoreFixtures
import Testing
import UIKit
@testable import PostGrid

/// A list card's select mode (the profile's Saved, the owner 2026-11-28):
/// History's behaviour — the whole card slides toward the trailing edge and
/// the circle comes in at the leading edge, shown only while the list edits
/// and checked once the card is selected; the card rests whole meanwhile,
/// so a tap anywhere on it reaches the list.
@MainActor
struct ListCardSelectModeTests {
    private static let width: CGFloat = 394
    private static let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())

    private static func post(id: String = "post-1", kind: GalleryPost.Kind = .photo, caption: String = "A saved post.") -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: kind, isRepost: false,
            thumbnailURL: kind == .text ? nil : URL(string: "https://example.com/\(id).jpg"),
            aspectRatio: 1, caption: caption, publishedAtMS: 0,
            authorID: ProfileID("ada"), authorName: "Ada Lovelace", authorHandle: "ada",
            reactionCount: 160, commentCount: 3
        )
    }

    private static func cell(_ post: GalleryPost = post()) -> PostGridListRowCell {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: width, height: 480))
        cell.dress = .row
        cell.configure(with: post, imagePipeline: pipeline)
        cell.layoutIfNeeded()
        return cell
    }

    private static func state(of cell: UICollectionViewCell, editing: Bool, selected: Bool) -> UICellConfigurationState {
        var state = UICellConfigurationState(traitCollection: cell.traitCollection)
        state.isEditing = editing
        state.isSelected = selected
        return state
    }

    /// At rest there is no circle, and the card takes its own touches.
    @Test func aCardAtRestWearsNoCircle() {
        let cell = Self.cell()
        cell.updateConfiguration(using: Self.state(of: cell, editing: false, selected: false))
        #expect(cell.debugSelectionMark == (shown: false, checked: false))
        #expect(cell.debugCardTakesTouches)
        #expect(cell.debugCardSlide == 0)
        #expect(!cell.isAccessibilityElement, "the card is one element at rest")
    }

    /// Selecting: the card slides by History's shift, the circle shows at
    /// the row's leading edge on the card's middle, empty until the card is
    /// selected, then checked; the card rests and speaks as one selectable
    /// element.
    @Test func theSelectModeShowsTheCircleAndChecksItOnSelection() {
        let cell = Self.cell()
        cell.updateConfiguration(using: Self.state(of: cell, editing: true, selected: false))
        #expect(cell.debugSelectionMark == (shown: true, checked: false))
        #expect(!cell.debugCardTakesTouches, "a part of the card still takes a tap in the select mode")
        #expect(cell.isAccessibilityElement)
        #expect(cell.accessibilityLabel == "A saved post.")
        #expect(!cell.accessibilityTraits.contains(.selected))

        let frame = cell.debugSelectionMarkFrame
        #expect(abs(frame.width - RowSelectionMark.side) < 0.5, "the circle's side: \(frame)")
        #expect(abs(frame.minX) < 0.5, "the circle is not at the row's leading edge: \(frame)")
        #expect(abs(cell.debugCardSlide - PostGridListRowCell.selectionShift) < 0.5, "the card is not slid: \(cell.debugCardSlide)")
        #expect(PostGridListRowCell.selectionShift == PostHistoryRowCell.selectionShift, "not History's shift")

        cell.updateConfiguration(using: Self.state(of: cell, editing: true, selected: true))
        #expect(cell.debugSelectionMark == (shown: true, checked: true))
        #expect(cell.accessibilityTraits.contains(.selected))
    }

    /// Leaving the mode takes the circle away, empties it and gives the card
    /// its touches back.
    @Test func leavingTheSelectModeHidesTheCircleAndWakesTheCard() {
        let cell = Self.cell()
        cell.updateConfiguration(using: Self.state(of: cell, editing: true, selected: true))
        cell.updateConfiguration(using: Self.state(of: cell, editing: false, selected: false))
        #expect(cell.debugSelectionMark == (shown: false, checked: false))
        #expect(cell.debugCardTakesTouches)
        #expect(cell.debugCardSlide == 0, "the card did not slide back")
        #expect(!cell.isAccessibilityElement)
        #expect(cell.accessibilityLabel == nil)
        #expect(!cell.accessibilityTraits.contains(.selected))
    }

    /// A card recycled while selecting speaks its new post's words, never
    /// the last one's.
    @Test func aRecycledCardSpeaksItsNewPost() {
        let cell = Self.cell()
        cell.updateConfiguration(using: Self.state(of: cell, editing: true, selected: false))
        cell.prepareForReuse()
        cell.configure(with: Self.post(id: "post-2", kind: .text, caption: "Another one."), imagePipeline: Self.pipeline)
        #expect(cell.accessibilityLabel == "Another one.")
        #expect(cell.debugSelectionMark.shown, "the mode is the list's: a recycled card keeps its circle")
    }

    /// A text card slides and wears the same circle at the same edge.
    @Test func aTextCardWearsTheSameCircle() {
        let cell = Self.cell(Self.post(kind: .text))
        cell.updateConfiguration(using: Self.state(of: cell, editing: true, selected: true))
        #expect(cell.debugSelectionMark == (shown: true, checked: true))
        let frame = cell.debugSelectionMarkFrame
        #expect(abs(frame.minX) < 0.5 && abs(cell.debugCardSlide - PostGridListRowCell.selectionShift) < 0.5)
    }
}
