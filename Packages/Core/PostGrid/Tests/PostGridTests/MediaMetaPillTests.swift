import CoreModels
import MediaCore
import UIKit
import Testing
@testable import PostGrid

// A card carries the same four values — views, reactions, comments, age — in
// one of two placements, and which one it is falls out of the post's kind: a
// quiet line closing a text card, two chips of glass on a media card's preview.
//
// What these pin is the part a visual check cannot see. The pills LOOK right in
// a screenshot whether or not the line under the preview went away with them,
// whether or not they conceal with the media a flight is carrying, and whether
// or not an empty capsule is being drawn for a post with nothing to count.

@MainActor
private func row(
    kind: GalleryPost.Kind,
    reactions: Int64? = 160,
    comments: Int64? = 12,
    views: Int64? = 4_200,
    width: CGFloat = 390
) -> PostGridListRowCell {
    let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: width, height: 400))
    cell.configure(
        with: GalleryPost(
            id: PostID("p"),
            kind: kind,
            isRepost: false,
            thumbnailURL: nil,
            caption: "A caption short enough to leave the card its own shape.",
            publishedAtMS: 0,
            reactionCount: reactions,
            commentCount: comments,
            viewCount: views
        ),
        imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
    )
    // The height a self-sizing cell would be given, resolved the way the layout
    // resolves it — the card's own opinion, not the frame it was built at.
    let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
    attributes.frame = cell.frame
    cell.bounds.size.height = cell.preferredLayoutAttributesFitting(attributes).frame.height
    cell.layoutIfNeeded()
    return cell
}

private func pills(in view: UIView) -> [PostMetaPillView] {
    if let pill = view as? PostMetaPillView { return [pill] }
    return view.subviews.flatMap(pills(in:))
}

/// Whether `view` is on screen at all, which is a question about its ANCESTORS
/// as much as itself: the pills live inside the preview, so a text row hides
/// them by hiding the preview and never touches the pills themselves.
private func isVisible(_ view: UIView, within root: UIView) -> Bool {
    var node: UIView? = view
    while let current = node, current !== root.superview {
        if current.isHidden || current.alpha == 0 { return false }
        node = current.superview
    }
    return true
}

@MainActor
struct MediaMetaPillPlacementTests {
    /// The point of moving the metadata: a media card ENDS at its preview.
    ///
    /// Asserted as arithmetic rather than as a height, because the height
    /// depends on the caption and the type size. The card closes at the same
    /// inset it holds the preview off its sides by, which is what keeps the
    /// curve concentric all the way round.
    @Test func aMediaCardClosesAtItsPreview() throws {
        let cell = row(kind: .photo)
        let preview = try #require(cell.mediaHeroRect)

        #expect(abs(cell.bounds.height - preview.maxY - PostGridListRowCell.mediaInset) < 0.5)
    }

    /// And the line it replaced is GONE, not merely covered. The check is the
    /// one above stated the other way round: a card still carrying a closing
    /// line below its preview is ~28pt taller than one that is not, so a
    /// duplicate would show up as slack under the media.
    @Test func aMediaCardHasNoClosingLineUnderThePreview() throws {
        let media = row(kind: .photo)
        let preview = try #require(media.mediaHeroRect)
        let slack = media.bounds.height - preview.maxY

        #expect(slack < PostGridListRowCell.metaBottomInset + 20)
    }

    /// A text row is untouched: no preview, so the metadata is still the quiet
    /// line that closes the card, and no pill is on screen anywhere.
    @Test func aTextCardKeepsItsClosingLine() {
        let cell = row(kind: .text)

        #expect(cell.mediaHeroRect == nil)
        #expect(pills(in: cell.contentView).allSatisfy { !isVisible($0, within: cell.contentView) })
    }

    /// Both pills are on the preview's bottom edge, counters leading and age
    /// trailing — the closing line's own reading order, kept.
    @Test func thePillsRestOnThePreviewsBottomEdge() throws {
        let cell = row(kind: .photo)
        let preview = try #require(cell.mediaHeroRect)
        let visible = pills(in: cell.contentView).filter { isVisible($0, within: cell.contentView) }
        #expect(visible.count == 2)

        let inset = PostGridListRowCell.mediaFurnitureInset
        for pill in visible {
            let frame = pill.convert(pill.bounds, to: cell.contentView)
            #expect(abs(preview.maxY - frame.maxY - inset) < 0.5)
        }
        let ordered = visible.map { $0.convert($0.bounds, to: cell.contentView) }
            .sorted { $0.minX < $1.minX }
        #expect(abs(ordered[0].minX - preview.minX - inset) < 0.5)
        #expect(abs(preview.maxX - ordered[1].maxX - inset) < 0.5)
    }
}

@MainActor
struct MediaMetaPillContentTests {
    /// A pill tracks its contents' ANSWER, not their presence.
    ///
    /// The counters hide themselves when the post carries no number — absence,
    /// not an asserted zero — and the leftover here is not a dimmed glyph but a
    /// filled capsule sitting on the photo.
    @Test func aPostWithNoCountersDrawsNoEmptyCapsule() throws {
        let cell = row(kind: .photo, reactions: nil, comments: nil, views: nil)
        let visible = pills(in: cell.contentView).filter { isVisible($0, within: cell.contentView) }

        // The age survives — every post has one — so what is left is the
        // trailing pill alone, not a leading capsule with nothing in it.
        #expect(visible.count == 1)
        let preview = try #require(cell.mediaHeroRect)
        let frame = visible[0].convert(visible[0].bounds, to: cell.contentView)
        #expect(abs(preview.maxX - frame.maxX - PostGridListRowCell.mediaFurnitureInset) < 0.5)
    }

    /// One counter is enough to earn the capsule.
    @Test func aSingleCounterStillGetsItsPill() {
        let cell = row(kind: .photo, reactions: 160, comments: nil, views: nil)
        let visible = pills(in: cell.contentView).filter { isVisible($0, within: cell.contentView) }

        #expect(visible.count == 2)
    }

    /// The rule, tested where it lives rather than only through a cell.
    @Test func aPillWithNothingShowingHidesItself() {
        let shown = UIView()
        let hidden = UIView()
        hidden.isHidden = true

        let empty = PostMetaPillView(contents: [hidden])
        empty.syncVisibilityToContents()
        #expect(empty.isHidden)

        let partial = PostMetaPillView(contents: [hidden, shown])
        partial.syncVisibilityToContents()
        #expect(partial.isHidden == false)
    }

    /// Glass is built on window attach and NEVER in init.
    ///
    /// Not a style rule: materializing an effect off-screen contacts the render
    /// server, and on a headless CI simulator that stalls the main actor for
    /// tens of seconds. These are cells, so an init-time effect would pay it per
    /// ROW. The suite that would hang is this one — it builds cells with no
    /// window at all — so the assertion is cheap and the regression it catches
    /// is a red CI run nobody would read as a rendering change.
    @Test func aPillOffScreenHasNoEffectYet() {
        let pill = PostMetaPillView(contents: [UIView()])

        #expect(pill.effect == nil)
    }

    /// ⚠️ The chip's ground follows the DEVICE, never the photo under it.
    ///
    /// `UIGlassEffect` is what this app floats every other piece of chrome on,
    /// so "make the chip match the rest of the app" is a change someone will
    /// reach for. It resolves its own luminance against its backdrop, which is
    /// right for chrome over a page and wrong for a chip on a photograph: the
    /// two chips on one card resolve independently, so a bright sky and a dark
    /// cliff put a light chip and a dark chip on the same image, and a chip
    /// flips side as the photo loads or a video starts. It reads as the app
    /// changing theme by itself.
    ///
    /// Asserted on the effect VALUE, which is why `makeBackdrop` exists —
    /// attaching one off-screen is what hangs a headless simulator.
    @Test func theChipsGroundFollowsTheInterfaceStyleAndNotTheBackdrop() {
        let backdrop = PostMetaPillView.makeBackdrop()

        #expect(backdrop is UIBlurEffect)
        #expect((backdrop is UIGlassEffect) == false)
    }
}

/// A card's shape system: which curve owes which other curve a radius, and
/// which owes nothing.
///
/// The concentric rule — a child's radius is its parent's less the inset — is
/// about CORNERS. Two curves turning together have a band between them, and
/// unless the radii differ by exactly the inset that band swells through the
/// turn. Along a straight edge there is no such constraint at all.
///
/// So the preview is concentric with the card, whose corners it sits on; and
/// the chips are capsules, because they are held clear of the preview's corners
/// and meet nothing but flat edge. The second half is the one a test has to
/// carry: it is invisible, it is what the capsule is standing on, and the
/// clearance would be the first thing "tidied" by anyone tightening the inset.
@MainActor
struct CardShapeSystemTests {
    @Test func thePreviewIsConcentricWithTheCard() {
        #expect(PostGridListRowCell.cardCornerRadius
            - PostGridListRowCell.mediaCornerRadius == PostGridListRowCell.mediaInset)
    }

    /// The preview's edges fall on the caption's, which is the whole reason
    /// `contentInset` is one constant serving both.
    @Test func thePreviewIsInsetLikeTheText() {
        #expect(PostGridListRowCell.mediaInset == PostGridListRowCell.captionInset)
    }

    /// ⚠️ The clearance the capsules rest on, stated as the inequality that
    /// matters rather than as the value that satisfies it today.
    ///
    /// A rounded rect's corner arc occupies a box of its own radius. A chip held
    /// further in than that from BOTH edges never enters it, so its own corners
    /// have no curve to agree with. Tighten this below the preview's radius and
    /// the chips move back inside the arc, where a ~10.5pt capsule against a
    /// 10pt corner is the equal-radii case: an 8pt band on the straights opening
    /// to 11.5 at 45°.
    @Test func theChipsAreHeldClearOfThePreviewsCornerArcs() {
        #expect(PostGridListRowCell.mediaFurnitureInset
            >= PostGridListRowCell.mediaCornerRadius)
    }

    /// And they really are laid out there, not merely allowed to be — measured
    /// off the realised frames, since the constant only governs the constraints.
    @Test func theChipsLandOutsideTheArcs() throws {
        let cell = row(kind: .photo)
        let preview = try #require(cell.mediaHeroRect)
        let arc = PostGridListRowCell.mediaCornerRadius
        let visible = pills(in: cell.contentView).filter { isVisible($0, within: cell.contentView) }
        #expect(visible.count == 2)

        // Half a point of slack, and it is not decoration: these are differences
        // of converted rects, so an exact `>=` compares 13.999999999999972
        // against 14 and fails on a layout that is right. Measured, not assumed
        // — that was the first run of this test.
        for pill in visible {
            let frame = pill.convert(pill.bounds, to: cell.contentView)
            #expect(frame.minX - preview.minX >= arc - 0.5)
            #expect(preview.maxX - frame.maxX >= arc - 0.5)
            #expect(preview.maxY - frame.maxY >= arc - 0.5)
        }
    }

    /// The chips are CAPSULES — pinned so the choice survives someone reading
    /// the concentric rule off the preview above them and "correcting" it.
    ///
    /// Read from `effectiveRadius` rather than from the corner configuration:
    /// `.capsule()` resolves itself against the bounds, so the only honest
    /// question is what UIKit actually drew.
    @Test func theChipsAreCapsules() throws {
        let cell = row(kind: .photo)
        let pill = try #require(
            pills(in: cell.contentView).first { isVisible($0, within: cell.contentView) }
        )

        #expect(abs(pill.effectiveRadius(corner: .allCorners) - pill.bounds.height / 2) < 0.5)
        // ⚠️ The second half, and the assertion above is worth little without
        // it. A resolved radius says the shape was CONFIGURED, not that it was
        // drawn: `UIGlassEffect` draws its own shape, a `UIBlurEffect` backdrop
        // fills the bounds and is clipped by the layer or not at all. Swapping
        // one for the other turned every capsule back into a rectangle while
        // this test stayed green — caught in a 3x crop of a screenshot, not
        // here.
        #expect(pill.clipsToBounds)
    }

}

@MainActor
struct MediaMetaPillConcealmentTests {
    /// CONCEAL EXACTLY WHAT THE FLIGHT REPRODUCES, and the pills are part of
    /// what it does not.
    ///
    /// A flight carries the preview's image and nothing else, so the chips
    /// resting on it have to leave with it — a capsule left floating on an
    /// empty rounded box for the length of a flight is the caption-vanishing
    /// defect at a smaller scale. They get there through the preview's own
    /// alpha, which is the whole reason they are built inside it: there is no
    /// second channel that could fall out of step.
    @Test func thePillsLeaveWithThePreviewTheyRestOn() {
        let cell = row(kind: .photo)
        // The chips ON SCREEN: a single-media row also holds a page indicator,
        // built for every row and hidden unless the post is a collection.
        let all = pills(in: cell.contentView)
            .filter { isVisible($0, within: cell.contentView) }
        #expect(all.count == 2)

        cell.setHeroMediaConcealed(true)
        #expect(all.allSatisfy { !isVisible($0, within: cell.contentView) })

        cell.setHeroMediaConcealed(false)
        #expect(all.allSatisfy { isVisible($0, within: cell.contentView) })
    }

    /// And the row still answers where its media is while they are gone — the
    /// rect the DISMISSAL flies home to, which is why concealment is alpha
    /// rather than `isHidden` in the first place.
    @Test func aConcealedPreviewStillReportsItsRect() {
        let cell = row(kind: .photo)
        let resting = cell.mediaHeroRect

        cell.setHeroMediaConcealed(true)

        #expect(cell.mediaHeroRect == resting)
    }
}
