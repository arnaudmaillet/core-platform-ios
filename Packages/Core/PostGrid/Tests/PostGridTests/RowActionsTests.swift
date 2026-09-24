import CoreModels
import MediaCore
import UIKit
import Testing
@testable import PostGrid

/// The row's closing line — comments, likes, repost, save — and the band above
/// it, which names the person and says when, and carries nothing a finger
/// presses but the "...".
@MainActor
struct RowActionsTests {
    private static func post(name: String = "Sofía", handle: String = "sofia") -> GalleryPost {
        GalleryPost(
            id: PostID("p"), kind: .text, isRepost: false,
            thumbnailURL: nil, caption: "A note.", publishedAtMS: 0,
            authorID: ProfileID("a"), authorName: name, authorHandle: handle,
            reactionCount: 160, commentCount: 12
        )
    }

    private func row(
        name: String = "Sofía", handle: String = "sofia", width: CGFloat = 343,
        wired: Bool = true
    ) -> PostGridListRowCell {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: width, height: 200))
        cell.configure(
            with: Self.post(name: name, handle: handle),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        if wired {
            cell.onRepostTapped = {}
            cell.onBookmarkTapped = {}
            cell.authorMenuActions = { [.report(perform: {})] }
        }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.frame = cell.frame
        cell.bounds.size.height = cell.preferredLayoutAttributesFitting(attributes).frame.height
        cell.layoutIfNeeded()
        return cell
    }

    private func buttons(in view: UIView) -> [UIButton] {
        func walk(_ view: UIView) -> [UIButton] {
            if let button = view as? UIButton { return [button] }
            return view.subviews.flatMap(walk)
        }
        return walk(view).filter { !$0.isHidden && $0.superviewChainIsVisible }
    }

    private func pills(in view: UIView) -> [PostMetaPillView] {
        func walk(_ view: UIView) -> [PostMetaPillView] {
            if let pill = view as? PostMetaPillView { return [pill] }
            return view.subviews.flatMap(walk)
        }
        return walk(view).filter { !$0.isHidden && $0.superviewChainIsVisible }
    }

    private func labels(in view: UIView) -> [UILabel] {
        if let label = view as? UILabel { return [label] }
        return view.subviews.flatMap(labels(in:))
    }

    private func band(in cell: PostGridListRowCell) -> PostAuthorBandView? {
        func walk(_ view: UIView) -> PostAuthorBandView? {
            if let band = view as? PostAuthorBandView { return band }
            for child in view.subviews { if let found = walk(child) { return found } }
            return nil
        }
        return walk(cell.contentView)
    }

    /// ⚠️ THE REQUIREMENT: one line of controls, at the foot of the card, and
    /// the band above carries only the "...".
    ///
    /// Two clusters of controls per card — repost and save beside the name,
    /// the counts under the caption — was the defect. Every button but the
    /// overflow now sits BELOW the caption, and the overflow is alone above it.
    @Test func everyControlButTheOverflowIsInTheClosingLine() throws {
        let cell = row()
        let captionLabel = try #require(labels(in: cell.contentView).first {
            $0.font == .preferredFont(forTextStyle: .body)
        })
        let caption = captionLabel.convert(captionLabel.bounds, to: cell.contentView)
        let controls = buttons(in: cell.contentView)
        #expect(controls.count == 3)

        let above = controls.filter { $0.convert($0.bounds, to: cell.contentView).maxY <= caption.minY }
        let below = controls.filter { $0.convert($0.bounds, to: cell.contentView).minY >= caption.maxY }
        #expect(above.count == 1)
        #expect(above.first?.accessibilityLabel == "More actions")
        #expect(below.map(\.accessibilityLabel) == ["Repost", "Save"])
    }

    /// The closing line reads `[comments][likes][repost][save]`, trailing —
    /// what the post has, then what the viewer can do with it.
    @Test func theClosingLineReadsCountsThenControls() {
        let cell = row()
        let ordered = pills(in: cell.contentView).sorted {
            $0.convert($0.bounds, to: cell.contentView).minX < $1.convert($1.bounds, to: cell.contentView).minX
        }
        #expect(ordered.count == 4)
        #expect(ordered[0] is PostCardPillView && !(ordered[0] is PostActionPillView))
        #expect(ordered[1] is PostCardPillView && !(ordered[1] is PostActionPillView))
        #expect(ordered[2] is PostActionPillView)
        #expect(ordered[3] is PostActionPillView)
        let trailing = cell.contentView.bounds.maxX
            - (ordered.last?.convert(ordered.last!.bounds, to: cell.contentView).maxX ?? 0)
        #expect(abs(trailing - PostGridListRowCell.captionInset) < 0.5)
    }

    /// ⚠️ Every capsule on the line is the SAME height, measured against a
    /// real counter chip rather than the constant — two pills that agree on a
    /// number and disagree on screen is the failure the shared height exists
    /// to make impossible.
    @Test func theControlsWearTheSamePillAsTheCounters() throws {
        let cell = row()
        let heights = pills(in: cell.contentView).map(\.bounds.height)
        let first = try #require(heights.first)
        #expect(first > 0)
        for height in heights { #expect(abs(height - first) < 0.5) }
        #expect(abs(first - PostMetaPillView.height) < 0.5)
    }

    /// A control with no handler is not drawn. The same rule the "..." follows:
    /// visibility tracks the ANSWER, never the presence of a provider.
    @Test func aControlWithNoHandlerIsNotDrawn() {
        let bare = row(wired: false)
        #expect(buttons(in: bare.contentView).isEmpty)

        bare.onBookmarkTapped = {}
        #expect(buttons(in: bare.contentView).map(\.accessibilityLabel) == ["Save"])
    }

    /// ⚠️ THE NAME GIVES WAY TO THE "...", never the other way round.
    ///
    /// A name and a handle are the compressible half of the band — they
    /// already truncate by tail — and a long one must give way rather than
    /// push the control off the card.
    @Test func aLongNameGivesWayToTheOverflow() throws {
        let squeezed = row(
            name: "Bartholomew Fitzgerald-Montgomery the Third",
            handle: "bartholomew.fitzgerald.montgomery.the.third",
            width: 300
        )
        let roomy = row(width: 300)
        let squeezedMenu = try #require(buttons(in: squeezed.contentView).first { $0.accessibilityLabel == "More actions" })
        let roomyMenu = try #require(buttons(in: roomy.contentView).first { $0.accessibilityLabel == "More actions" })
        #expect(abs(squeezedMenu.bounds.width - roomyMenu.bounds.width) < 0.5)
        #expect(squeezedMenu.convert(squeezedMenu.bounds, to: squeezed.contentView).maxX
            <= squeezed.contentView.bounds.width + 0.5)

        func labels(_ view: UIView) -> [UILabel] {
            if let label = view as? UILabel { return [label] }
            return view.subviews.flatMap(labels)
        }
        let nameLabel = try #require(labels(squeezed.contentView).first { $0.text?.hasPrefix("Bartholomew") == true })
        #expect(nameLabel.bounds.width < nameLabel.intrinsicContentSize.width)
    }

    /// The date lives on the handle's line — "@handle · now" — and nowhere
    /// else on the card: the closing line is controls only.
    @Test func theDateSitsOnTheHandlesLine() throws {
        let cell = row()
        let age = PostMetadata.compactAge(ofMillis: 0)
        func labels(_ view: UIView) -> [UILabel] {
            if let label = view as? UILabel { return [label] }
            return view.subviews.flatMap(labels)
        }
        let visible = labels(cell.contentView).filter { !$0.isHidden && $0.superviewChainIsVisible }
        let dated = visible.filter { $0.text?.contains(age) == true }
        #expect(dated.count == 1)
        #expect(dated.first?.text == "@sofia · \(age)")
        #expect(cell.renderedAgeText == age)
    }

    /// The name leads the card's type: the caption's size, in bold, so who
    /// said it outranks what they said, and the handle a step below both.
    @Test func theNameIsBoldAtTheCaptionsSizeAndTheHandleAStepBelow() throws {
        let cell = row()
        func labels(_ view: UIView) -> [UILabel] {
            if let label = view as? UILabel { return [label] }
            return view.subviews.flatMap(labels)
        }
        let name = try #require(labels(cell.contentView).first { $0.text == "Sofía" })
        let handle = try #require(labels(cell.contentView).first { $0.text?.hasPrefix("@sofia") == true })
        #expect(name.font.pointSize == UIFont.preferredFont(forTextStyle: .body).pointSize)
        #expect(name.font.fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(handle.font.pointSize < name.font.pointSize)
    }

    /// The save control reports the store's answer and never its own: it is set
    /// from outside, before and after a toggle, so a store that refused would
    /// leave the glyph telling the truth.
    @Test func theSaveGlyphFollowsTheStateItIsGiven() {
        let cell = row()
        cell.isBookmarked = true
        #expect(cell.visibleRowActions.saved)
        cell.onBookmarkTapped?()
        #expect(cell.visibleRowActions.saved)
        cell.isBookmarked = false
        #expect(!cell.visibleRowActions.saved)
    }

    /// A stand-in card must match the ROW, not the design: a surface that wired
    /// neither control shows neither, and a stand-in drawing all three would end
    /// every dismissal with two controls vanishing.
    @Test func aStandInIsToldWhatTheRowActuallyDraws() {
        let wired = row()
        let standIn = row(wired: false)
        let shown = wired.visibleRowActions

        standIn.showRowActionsAsScenery(repost: shown.repost, bookmark: shown.bookmark, saved: shown.saved)

        #expect(standIn.visibleRowActions == shown)
    }

    /// ⚠️ A BARE band — a profile's own rows — names nobody and keeps the
    /// date and the "...", on a line a pill tall rather than a disc tall.
    @Test func aBareBandKeepsTheDateAndTheOverflowOnAShorterLine() throws {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: 343, height: 200))
        cell.configure(
            with: Self.post(), imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            showsAuthorIdentity: false
        )
        cell.authorMenuActions = { [.report(perform: {})] }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.frame = cell.frame
        cell.bounds.size.height = cell.preferredLayoutAttributesFitting(attributes).frame.height
        cell.layoutIfNeeded()

        let band = try #require(band(in: cell))
        #expect(abs(band.bounds.height - PostAuthorBandView.bareHeight) < 0.5)
        #expect(cell.revealCaptionTop == PostAuthorBandView.captionOffset(showsIdentity: false))
        #expect(cell.authorBandModel?.showsIdentity == false)

        func labels(_ view: UIView) -> [UILabel] {
            if let label = view as? UILabel { return [label] }
            return view.subviews.flatMap(labels)
        }
        let visible = labels(band).filter { !$0.isHidden && $0.superviewChainIsVisible }
        #expect(visible.map(\.text) == [PostMetadata.compactAge(ofMillis: 0)])
        #expect(buttons(in: band).map(\.accessibilityLabel) == ["More actions"])
    }

    /// And a post that carries no author at all is bare whatever the caller
    /// asks — there is nobody to draw.
    @Test func anUnauthoredPostIsBare() {
        let post = GalleryPost(
            id: PostID("p"), kind: .text, isRepost: false, thumbnailURL: nil,
            caption: "A note.", publishedAtMS: 0
        )
        #expect(PostAuthorBandView.Model(post: post).showsIdentity == false)
        #expect(PostAuthorBandView.Model(post: post, showsIdentity: true).showsIdentity == false)
        #expect(PostAuthorBandView.Model(post: Self.post(), showsIdentity: false).showsIdentity == false)
        #expect(PostAuthorBandView.Model(post: Self.post()).showsIdentity)
    }

    /// The stand-in's date is the ROW's reading, carried on the model.
    @Test func anOverriddenAgeTravelsOnTheModel() {
        let cell = row()
        cell.overrideAgeText("7m")
        #expect(cell.renderedAgeText == "7m")
        #expect(cell.authorBandModel?.age == "7m")
        #expect(cell.authorBandModel?.handle == "sofia")
    }
}
