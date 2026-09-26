import CoreModels
import MediaCore
import UIKit
import Testing
@testable import PostGrid

// A card closes on ONE line — comments, likes, and whatever controls the host
// wired — under the caption of a text card and under the preview of a media
// card. The preview itself wears nothing but the page indicator: what a viewer
// can press about a post is in the closing line, and the picture stays a
// picture.
//
// What these pin is the part a visual check cannot see: that the closing line
// is the same line on both shapes, that a media card's preview carries no
// counters, and that an empty capsule is never drawn for a post with nothing
// to count.

@MainActor
private func row(
    kind: GalleryPost.Kind,
    reactions: Int64? = 160,
    comments: Int64? = 12,
    views: Int64? = 4_200,
    pages: Int = 1,
    width: CGFloat = 390,
    publishedAtMS: Int64 = 0
) -> PostGridListRowCell {
    let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: width, height: 400))
    let page = GalleryPost.MediaPage(thumbnailURL: URL(string: "mock://photo/1"))
    cell.configure(
        with: GalleryPost(
            id: PostID("p"),
            kind: kind,
            isRepost: false,
            pages: kind == .text ? [] : Array(repeating: page, count: pages),
            caption: "A caption short enough to leave the card its own shape.",
            publishedAtMS: publishedAtMS,
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
/// as much as itself: the indicator lives inside the preview, so a text row
/// hides it by hiding the preview and never touches the indicator itself.
private func isVisible(_ view: UIView, within root: UIView) -> Bool {
    var node: UIView? = view
    while let current = node, current !== root.superview {
        if current.isHidden || current.alpha == 0 { return false }
        node = current.superview
    }
    return true
}

private func visiblePills(in cell: PostGridListRowCell) -> [PostMetaPillView] {
    pills(in: cell.contentView).filter { isVisible($0, within: cell.contentView) }
}

@MainActor
struct MediaMetaPillPlacementTests {
    /// The point of one closing line: a media card ends at it, under the
    /// preview, at the same inset a text card keeps under its own.
    @Test func aMediaCardClosesOnItsLineUnderThePreview() throws {
        let cell = row(kind: .photo)
        let preview = try #require(cell.mediaHeroRect)
        let line = visiblePills(in: cell)
        #expect(line.count == 2)
        for pill in line {
            let frame = pill.convert(pill.bounds, to: cell.contentView)
            #expect(frame.minY >= preview.maxY + PostGridListRowCell.captionFollowGap - 0.5)
            #expect(abs(cell.bounds.height - frame.maxY - PostGridListRowCell.metaBottomInset) < 0.5)
        }
    }

    /// And the preview carries NO counters: the two capsules on a media card
    /// are the same two a text card has, under the preview rather than on it.
    @Test func thePreviewWearsNoCounters() throws {
        let cell = row(kind: .photo)
        let preview = try #require(cell.mediaHeroRect)
        for pill in visiblePills(in: cell) {
            let frame = pill.convert(pill.bounds, to: cell.contentView)
            #expect(!frame.intersects(preview))
        }
    }

    /// ⚠️ A text row wears the SAME line, at the caption's inset.
    ///
    /// Measured at the TRAILING edge: the counters close the row on both of a
    /// card's shapes, and there is no date leading it any more — the date is
    /// on the band's handle line.
    @Test func aTextCardWearsTheSameLineInItsOwnColumn() {
        let cell = row(kind: .text)
        let visible = visiblePills(in: cell)

        #expect(cell.mediaHeroRect == nil)
        #expect(visible.count == 2)
        for pill in visible {
            let frame = pill.convert(pill.bounds, to: cell.contentView)
            #expect(cell.contentView.bounds.maxX - frame.maxX
                        >= PostGridListRowCell.captionInset - 0.5)
        }
        let trailing = visible
            .map { cell.contentView.bounds.maxX - $0.convert($0.bounds, to: cell.contentView).maxX }
            .min() ?? 0
        #expect(abs(trailing - PostGridListRowCell.captionInset) < 0.5)
    }

    /// The two shapes agree about the line: same capsules, same order
    /// (comments then likes), same trailing inset, same distance from the
    /// card's foot.
    @Test func bothShapesCloseOnTheSameLine() {
        let text = row(kind: .text)
        let media = row(kind: .photo)
        func line(_ cell: PostGridListRowCell) -> [(CGFloat, CGFloat)] {
            visiblePills(in: cell)
                .map { $0.convert($0.bounds, to: cell.contentView) }
                .sorted { $0.minX < $1.minX }
                .map { (cell.contentView.bounds.maxX - $0.maxX, cell.bounds.height - $0.maxY) }
        }
        let textLine = line(text)
        let mediaLine = line(media)
        #expect(textLine.count == mediaLine.count)
        for (a, b) in zip(textLine, mediaLine) {
            #expect(abs(a.0 - b.0) < 0.5)
            #expect(abs(a.1 - b.1) < 0.5)
        }
    }

    /// The page indicator is on the closing line, LEADING it — with the
    /// controls, before the counters — under the preview rather than on it,
    /// and a pill tall like everything else on the line.
    @Test func theIndicatorLeadsTheClosingLineUnderThePreview() throws {
        let cell = row(kind: .photo, pages: 3)
        let preview = try #require(cell.mediaHeroRect)
        func indicators(_ view: UIView) -> [MediaPageIndicatorView] {
            if let chip = view as? MediaPageIndicatorView { return [chip] }
            return view.subviews.flatMap(indicators)
        }
        let chip = try #require(
            indicators(cell.contentView).first { isVisible($0, within: cell.contentView) }
        )
        let frame = chip.convert(chip.bounds, to: cell.contentView)
        #expect(frame.minY >= preview.maxY)
        #expect(abs(frame.height - PostMetaPillView.height) < 0.5)
        // An unauthored post wears a bare band, so its date leads the line
        // and the indicator follows it; both are in the leading half.
        #expect(frame.minX >= PostGridListRowCell.captionInset - 0.5)
        #expect(frame.midX < cell.bounds.midX)
        for pill in visiblePills(in: cell) where !(pill is MediaPageIndicatorView) {
            let counter = pill.convert(pill.bounds, to: cell.contentView)
            #expect(counter.minX > frame.maxX)
            #expect(abs(counter.midY - frame.midY) < 0.5)
        }
    }

    /// ⚠️ THE INDICATOR YIELDS FIRST. On a narrow card the counts keep their
    /// full width and the run of dots shortens; a clipped count is a wrong
    /// count, a shorter run of dots still says "there is more".
    @Test func theIndicatorGivesWayBeforeTheCounts() throws {
        // A RECENT date, so the bare band's line carries "1h" rather than a
        // full 1970 date that would fill the row on its own and put every
        // chip below its floor — nothing to measure then.
        let ninetyMinutesAgo = Int64(Date().timeIntervalSince1970 * 1000) - 90 * 60 * 1000
        let wide = row(
            kind: .photo, reactions: 1_600_000, comments: 128_000, pages: 12, width: 390,
            publishedAtMS: ninetyMinutesAgo
        )
        // Narrow enough that five dots no longer fit beside two six-figure
        // counts, wide enough that two still do. (286, not 262: the
        // counters' glyphs grew to the controls' size on 2026-09-26, which
        // takes ~16pt more of the line — still far narrower than any phone,
        // an iPhone SE's card is ~343.)
        let narrow = row(
            kind: .photo, reactions: 1_600_000, comments: 128_000, pages: 12, width: 286,
            publishedAtMS: ninetyMinutesAgo
        )
        func indicator(_ cell: PostGridListRowCell) -> MediaPageIndicatorView? {
            func walk(_ view: UIView) -> [MediaPageIndicatorView] {
                if let chip = view as? MediaPageIndicatorView { return [chip] }
                return view.subviews.flatMap(walk)
            }
            return walk(cell.contentView).first
        }
        let wideChip = try #require(indicator(wide))
        let narrowChip = try #require(indicator(narrow))
        #expect(narrowChip.bounds.width < wideChip.bounds.width)
        #expect(narrowChip.bounds.width >= narrowChip.minimumChipWidth - 0.5)
        for pill in visiblePills(in: narrow) where !(pill is MediaPageIndicatorView) {
            let wanted = pill.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
            #expect(pill.bounds.width >= wanted - 0.5)
        }
    }

    /// The indicator wears the card's own fill, like the capsules beside it,
    /// and draws its dots in the card's ink — white dots on a light capsule
    /// would be no dots at all.
    @Test func theIndicatorWearsTheCardsFillAndInk() throws {
        let cell = row(kind: .photo, pages: 3)
        func indicators(_ view: UIView) -> [MediaPageIndicatorView] {
            if let chip = view as? MediaPageIndicatorView { return [chip] }
            return view.subviews.flatMap(indicators)
        }
        let chip = try #require(indicators(cell.contentView).first)
        let counter = try #require(visiblePills(in: cell).first { !($0 is MediaPageIndicatorView) })
        #expect(chip.contentView.backgroundColor == counter.contentView.backgroundColor)
        #expect(chip.contentView.backgroundColor == .tertiarySystemFill)
        func dots(_ view: UIView) -> [UIView] {
            let own = view.subviews.filter { $0.layer.cornerRadius == MediaPageIndicatorView.dotDiameter / 2 && $0.bounds.width > 0 }
            return own + view.subviews.flatMap(dots)
        }
        let drawn = dots(chip).filter { $0.alpha > 0 }
        #expect(!drawn.isEmpty)
        for dot in drawn {
            #expect(dot.backgroundColor == PostMetaPillView.foreground)
            #expect(dot.layer.shadowOpacity == 0)
        }
    }

    /// A single photograph shows no indicator at all.
    @Test func aSinglePhotographHasNoIndicator() {
        let cell = row(kind: .photo)
        func indicators(_ view: UIView) -> [MediaPageIndicatorView] {
            if let chip = view as? MediaPageIndicatorView { return [chip] }
            return view.subviews.flatMap(indicators)
        }
        #expect(indicators(cell.contentView).allSatisfy { !isVisible($0, within: cell.contentView) })
    }
}

/// What a mosaic BRICK carries, which is deliberately less than a card does.
@MainActor
struct TileMetaTests {
    /// ⚠️ ONE NUMBER ON A TILE, and it is reach rather than approval.
    ///
    /// A brick is small and read at a glance in a mosaic of a dozen others; two
    /// numbers on it are two things to compare across every tile at once. The
    /// heart is what the POST is for and the card carries it — a tile is a way
    /// IN, so how many got here is the number that earns the space.
    ///
    /// Counted by walking for metric labels rather than by naming a field: a
    /// second counter added back under another name is the regression.
    @Test func aTileCarriesTheViewCountAlone() {
        func metrics(_ view: UIView) -> [PostMetricLabel] {
            if let label = view as? PostMetricLabel { return [label] }
            return view.subviews.flatMap(metrics)
        }
        let cell = PostGridTileCell(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
        cell.configure(
            with: GalleryPost(
                id: PostID("post-1"), kind: .photo, isRepost: false,
                thumbnailURL: URL(string: "mock://photo/1"), caption: "A caption.",
                publishedAtMS: 0, reactionCount: 160, commentCount: 12, viewCount: 4_200
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        cell.layoutIfNeeded()

        let visible = metrics(cell.contentView).filter { isVisible($0, within: cell.contentView) }
        #expect(visible.count == 1)
        // And it closes the row, like the counters on a card.
        let frame = visible[0].convert(visible[0].bounds, to: cell.contentView)
        #expect(cell.contentView.bounds.maxX - frame.maxX < frame.minX)
    }
}

@MainActor
struct MediaMetaPillContentTests {
    /// A pill tracks its contents' ANSWER, not their presence.
    ///
    /// The counters hide themselves when the post carries no number — absence,
    /// not an asserted zero — and the leftover would be a filled capsule with
    /// nothing in it.
    @Test func aPostWithNoCountersDrawsNoEmptyCapsule() {
        let cell = row(kind: .photo, reactions: nil, comments: nil, views: nil)
        #expect(visiblePills(in: cell).isEmpty)
    }

    /// ⚠️ EACH CHIP ANSWERS FOR ITS OWN NUMBER.
    ///
    /// One capsule per verb — how many liked it, how many said something — so a
    /// post with likes and no comments draws one counter chip, not one chip with
    /// half its contents missing. Views are carried by the model and rendered on
    /// no card at all.
    @Test func eachCounterEarnsItsOwnCapsule() {
        #expect(visiblePills(in: row(kind: .photo, reactions: nil, comments: nil, views: 4_200)).count == 0)
        #expect(visiblePills(in: row(kind: .photo, reactions: 160, comments: nil, views: nil)).count == 1)
        #expect(visiblePills(in: row(kind: .photo, reactions: 160, comments: 12, views: nil)).count == 2)
    }

    /// The controls join the line only when the host wired them — a capsule
    /// per control, beside the counters.
    @Test func wiredControlsJoinTheLineOneCapsuleEach() {
        let cell = row(kind: .text)
        #expect(visiblePills(in: cell).count == 2)
        cell.onBookmarkTapped = {}
        #expect(visiblePills(in: cell).count == 3)
        cell.onRepostTapped = {}
        #expect(visiblePills(in: cell).count == 4)
        #expect(visiblePills(in: cell).filter { $0 is PostActionPillView }.count == 2)
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
/// the indicator is a capsule, because it is held clear of the preview's
/// corners and meets nothing but flat edge. The second half is the one a test
/// has to carry: it is invisible, it is what the capsule is standing on, and
/// the clearance would be the first thing "tidied" by anyone tightening the
/// inset.
@MainActor
struct CardShapeSystemTests {
    @Test func thePreviewIsConcentricWithTheCard() {
        #expect(PostGridListRowCell.cardCornerRadius
            - PostGridListRowCell.mediaCornerRadius == PostGridListRowCell.mediaInset)
    }

    /// The preview's edges fall on the caption's, which is the whole reason
    /// the inset is shared.
    @Test func thePreviewSitsOnTheCaptionsColumn() {
        #expect(PostGridListRowCell.mediaInset == PostGridListRowCell.captionInset)
    }

    /// Furniture on the preview starts outside its corner arcs, whatever the
    /// padding is — a floor, not a preference.
    @Test func furnitureClearsThePreviewsCorners() {
        #expect(PostGridListRowCell.mediaFurnitureInset >= PostGridListRowCell.mediaCornerRadius)
        #expect(PostGridListRowCell.mediaFurnitureInset >= PostGridListRowCell.contentInset)
    }
}
