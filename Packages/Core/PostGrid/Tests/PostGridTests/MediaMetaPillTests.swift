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

/// ⚠️ A CHIP IS A BOX ON THE ROW; a PILL is a box with a capsule.
///
/// Three of the preview's four wear one. The date does not — a capsule claims
/// its contents can be pressed, and it is the one thing on that row that never
/// will be — so it keeps the box and stands on a fading material instead.
/// Tests about PLACEMENT want all four; tests about the capsule want three.
private func chips(in view: UIView) -> [UIView] {
    if view is PostMetaPillView || view is PostChipSlotView { return [view] }
    return view.subviews.flatMap(chips(in:))
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

    /// ⚠️ A text row wears the SAME TWO CHIPS, at its own card's inset.
    ///
    /// It used to close on a bare pair of grey labels, which was right while the
    /// preview's chips were a legibility device and nothing more. They are
    /// becoming buttons, and an affordance that appears only when the post
    /// happens to carry a photograph is not one.
    ///
    /// The DATE is the deliberate exception and is asserted as such: it stays a
    /// bare label, because a capsule on this card reads as a control and the
    /// date is not one. Two chips, not three.
    @Test func aTextCardWearsTheSameCountersInItsOwnColumn() {
        let cell = row(kind: .text)
        let visible = pills(in: cell.contentView).filter { isVisible($0, within: cell.contentView) }

        #expect(cell.mediaHeroRect == nil)
        #expect(visible.count == 2)
        // ⚠️ At the CAPTION's inset, not at the preview's furniture inset.
        //
        // Matching the media card's 26 would have been the tidy answer to "they
        // are misaligned" and is the wrong one: that 26 is 12 to the preview
        // plus 14 to clear its corner arc — a rule that exists because there is
        // an arc. On a card with no preview it would only indent the closing
        // line away from the caption above it, trading a real alignment for an
        // abstract one.
        for pill in visible {
            let frame = pill.convert(pill.bounds, to: cell.contentView)
            #expect(frame.minX >= PostGridListRowCell.captionInset - 0.5)
        }
        let leading = visible
            .map { $0.convert($0.bounds, to: cell.contentView).minX }
            .min() ?? 0
        #expect(abs(leading - PostGridListRowCell.captionInset) < 0.5)
    }

    /// ⚠️ The closing line's INK is symmetric, which its constraints are not.
    ///
    /// Pinning the row at `captionInset` on both sides aligns the capsules'
    /// EDGES with the caption and reads correctly as code. On screen the leading
    /// number starts a pill's padding further in, so the ink ran 24 on the left
    /// against 12 on the right and the date looked shoved against the card.
    ///
    /// Measured off the DATE's own frame rather than the row's, because the row
    /// is exactly the thing that was already symmetric while the card was not.
    @Test func theClosingLinesDateIsInsetLikeAChipsText() throws {
        let cell = row(kind: .text)
        let age = PostMetadata.compactAge(ofMillis: 0)

        func labels(_ view: UIView) -> [UILabel] {
            if let label = view as? UILabel { return [label] }
            return view.subviews.flatMap(labels)
        }
        // ⚠️ Filtered by VISIBILITY, and it matters: the card builds both shapes
        // and hides one, so the preview's own age label carries the same string
        // from inside the hidden preview. Without this the test measured that
        // one and failed by 101pt — which is the same trap the pill counts hit.
        let date = try #require(
            labels(cell.contentView).first {
                $0.text == age && isVisible($0, within: cell.contentView)
            }
        )
        let frame = date.convert(date.bounds, to: cell.contentView)
        let trailingGap = cell.contentView.bounds.maxX - frame.maxX

        let chip = try #require(
            pills(in: cell.contentView).first { isVisible($0, within: cell.contentView) }
        )
        let leadingGap = chip.convert(chip.bounds, to: cell.contentView).minX
            + PostMetaPillView.insets.leading

        #expect(abs(trailingGap - leadingGap) < 1)
        // And it really moved: the naive pinning would put it at the row's own
        // inset, which is a pill's padding closer to the edge.
        #expect(trailingGap > PostGridListRowCell.captionInset + 1)
    }

    /// Every chip rests on the preview's bottom edge — likes and comments
    /// leading, age trailing, the closing line's own reading order kept.
    @Test func thePillsRestOnThePreviewsBottomEdge() throws {
        let cell = row(kind: .photo)
        let preview = try #require(cell.mediaHeroRect)
        let visible = chips(in: cell.contentView).filter { isVisible($0, within: cell.contentView) }
        // Likes, comments, age. No indicator: this post is one photograph.
        #expect(visible.count == 3)

        let inset = PostGridListRowCell.mediaFurnitureInset
        for pill in visible {
            let frame = pill.convert(pill.bounds, to: cell.contentView)
            #expect(abs(preview.maxY - frame.maxY - inset) < 0.5)
        }
        let ordered = visible.map { $0.convert($0.bounds, to: cell.contentView) }
            .sorted { $0.minX < $1.minX }
        #expect(abs(ordered[0].minX - preview.minX - inset) < 0.5)
        #expect(abs(preview.maxX - ordered[2].maxX - inset) < 0.5)
        // And they never touch: one gap between the two counters.
        #expect(ordered[1].minX - ordered[0].maxX >= PostGridListRowCell.chipGap - 0.5)
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
        let capsules = pills(in: cell.contentView).filter { isVisible($0, within: cell.contentView) }
        let boxes = chips(in: cell.contentView).filter { isVisible($0, within: cell.contentView) }

        // NO capsule at all — and the age still drawn, in its own bare box at
        // the trailing edge. Counting boxes and capsules separately is the point
        // of the test: a regression that gave the date a capsule back, or one
        // that dropped the date with the counters, moves exactly one of them.
        #expect(capsules.isEmpty)
        #expect(boxes.count == 1)
        let preview = try #require(cell.mediaHeroRect)
        let frame = boxes[0].convert(boxes[0].bounds, to: cell.contentView)
        #expect(abs(preview.maxX - frame.maxX - PostGridListRowCell.mediaFurnitureInset) < 0.5)
    }

    /// ⚠️ THE PREVIEW'S DATE IS WHITE ON A BLACK HALO, and the halo is not
    /// optional decoration — it is the only thing holding the word up.
    ///
    /// The date is the one piece of the row with no ground under it. An earlier
    /// version sampled the picture and chose a side; `MediaDateInk` records why
    /// that was dropped. What replaced it only works as a PAIR, so both halves
    /// are asserted here: a white word with the shadow turned off is invisible
    /// on any bright photograph, and nothing else in the cell would notice.
    @Test func thePreviewsDateIsWhiteAndCarriesItsOwnHalo() throws {
        let cell = row(kind: .photo)
        let age = PostMetadata.compactAge(ofMillis: 0)
        func labels(_ view: UIView) -> [UILabel] {
            if let label = view as? UILabel { return [label] }
            return view.subviews.flatMap(labels)
        }
        let date = try #require(
            labels(cell.contentView).first {
                $0.text == age && isVisible($0, within: cell.contentView)
            }
        )

        #expect(date.textColor == MediaDateInk.colour)
        #expect(date.layer.shadowColor == MediaDateInk.halo.cgColor)
        #expect(date.layer.shadowOpacity > 0)
        #expect(date.layer.shadowRadius > 0)
        // And the halo really is the other side, whatever the ink becomes.
        #expect(MediaDateInk.halo != MediaDateInk.colour)
    }

    /// ⚠️ EACH CHIP ANSWERS FOR ITS OWN NUMBER.
    ///
    /// One capsule per verb — how many liked it, how many said something — so a
    /// post with likes and no comments draws one counter chip, not one chip with
    /// half its contents missing. Views are carried by the model and rendered on
    /// no card at all.
    @Test func eachCounterEarnsItsOwnCapsule() {
        func shown(_ cell: PostGridListRowCell) -> Int {
            pills(in: cell.contentView).filter { isVisible($0, within: cell.contentView) }.count
        }

        // The date is not counted here — it wears no capsule.
        #expect(shown(row(kind: .photo, reactions: nil, comments: nil, views: 4_200)) == 0)
        #expect(shown(row(kind: .photo, reactions: 160, comments: nil, views: nil)) == 1)
        #expect(shown(row(kind: .photo, reactions: 160, comments: 12, views: nil)) == 2)
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
        let visible = chips(in: cell.contentView).filter { isVisible($0, within: cell.contentView) }
        #expect(visible.count == 3)

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

    /// ⚠️ The band's cluster pill sits IN the card's top-right corner, and its
    /// curve is the concentric answer to that corner's.
    ///
    /// It was centred on the avatar, which put it below the arc where its curve
    /// answered to nothing. Inset from both edges by `contentInset`, the rule
    /// says its radius should be the card's less that inset — 26 - 12 = 14 —
    /// and a capsule this tall resolves to 14.5. It is the right shape already;
    /// what this pins is that it stays in the place where that is TRUE, because
    /// nothing about the capsule itself would change if someone re-centred it.
    @Test func theClusterPillTurnsWithTheCardsCorner() throws {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        cell.configure(
            with: GalleryPost(
                id: PostID("p"), kind: .photo, isRepost: false,
                thumbnailURL: nil, caption: "Short.", publishedAtMS: 0,
                authorID: ProfileID("a"), authorName: "Sofía Reyes", authorHandle: "sofia.reyes"
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        cell.onRepostTapped = {}
        cell.onBookmarkTapped = {}
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.frame = cell.frame
        cell.bounds.size.height = cell.preferredLayoutAttributesFitting(attributes).frame.height
        cell.layoutIfNeeded()

        // The card is pinned to the content view, so the content view IS the
        // card's box.
        // Found by ANCESTRY, not by `superview`: the band nests its cluster, and
        // a direct-parent check silently stopped finding this pill the moment
        // the "..." moved out of it and a stack appeared in between.
        func isInsideBand(_ view: UIView) -> Bool {
            sequence(first: view, next: \.superview).contains { $0 is PostAuthorBandView }
        }
        let cluster = try #require(pills(in: cell.contentView).first(where: isInsideBand))
        let frame = cluster.convert(cluster.bounds, to: cell.contentView)
        let inset = PostGridListRowCell.contentInset

        #expect(abs(frame.minY - inset) < 0.5)
        #expect(abs(cell.contentView.bounds.maxX - frame.maxX - inset) < 0.5)
        // Concentric within half a point of the rule.
        let concentric = PostGridListRowCell.cardCornerRadius - inset
        #expect(abs(cluster.effectiveRadius(corner: .allCorners) - concentric) <= 0.5)
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
        // Chips, not capsules: the date wears no capsule and still has to leave
        // with the picture.
        let all = chips(in: cell.contentView)
            .filter { isVisible($0, within: cell.contentView) }
        // Likes, comments, age.
        #expect(all.count == 3)

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
