import DesignSystem
import UIKit

/// The single geometry authority for the comments engagement — the pure
/// in-cell layout mutation between the page's two states:
///
///   NORMAL:  full-bleed media under the overlay chrome.
///   ENGAGED: [nav identity pill]                  — screen chrome, untouched
///            [media │ caption          ]          ┐ the CARD — the post
///            [      │ ♫ music line     ]          │ reformatted: media
///            [      │ ♥ 💬 ⇄ save      ]          ┘ left, one column right
///            [comments container → cell bottom]   — cell-owned, child view
///
/// (Author identity deliberately does NOT appear in the card: the nav
/// pill — screen chrome — already carries it, and fading the pill means
/// fighting its glass platter. One identity, zero duplication.)
///
/// ONE surface, one motion profile: every element of the mutation lives in
/// the cell's own hierarchy and animates in a single spring block (the
/// sheet, the custom presentation controller, and the reveal animators that
/// preceded this design are gone — each split the screen into two motion
/// systems, and each read as exactly that). The media view's constraints/
/// transform animate in place, so playback is untouchable by construction.
///
/// Every number the mutation depends on lives HERE, as pure functions of
/// the cell bounds and the frozen top inset (the feed's pushed-threshold
/// doctrine), so the strip and the comments region partition the page
/// exactly.
enum SnapCommentsLayout {
    /// The docked media's side: the slot is a perfect 1:1 SQUARE, compact
    /// (thumbnail-sized — the strip is an index card, not a viewer; the
    /// engaged screen belongs to the comments). 88, not the original 128:
    /// the tile sets the whole card's height, and the column beside it
    /// (caption / music / actions) reads balanced at this size where 128
    /// left a dead gap under short captions. The media still shrinks as
    /// a uniform scale (no distortion) — squareness comes from an animated
    /// center-crop mask (`mediaCropFrame`), so the docked tile re-crops the
    /// full-bleed content rather than squashing it.
    static let mediaSlotHeight: CGFloat = 88
    /// The docked media's visual corner radius (compensated for the
    /// transform's scale when applied to the full-size layer) —
    /// proportioned to the 88pt tile.
    static let mediaCornerRadius: CGFloat = 12
    static let stripTopPadding: CGFloat = Spacing.sm
    static let stripBottomPadding: CGFloat = Spacing.md

    // MARK: The card's interior
    //
    // The engaged card is the POST, reformatted — not a caption summary,
    // and not a stack of bands: ONE horizontal split. The media square
    // owns the left edge; a single vertical column beside it hosts the
    // caption, the music/attribution line, and the metrics/actions row,
    // bottom-anchored in that order. The card is exactly one media row
    // tall, so its height — and with it `stripBottom`, the comments
    // partition — stays a pure function of the constants.

    /// The metrics/actions row at the column's bottom: likes, comments,
    /// repost, save. Sized with the 88pt column: every point spent here
    /// comes out of the caption's line budget. (No music line: the native
    /// toolbar stays onstage through the engagement — keep-and-stack —
    /// and its attribution item owns the audio credit.)
    static let cardActionsHeight: CGFloat = 24
    /// The card content's entrance micro-translation — the rows rise into
    /// place as they fade in, the composer-entrance recipe at card scale.
    static let cardContentEntranceOffset: CGFloat = 12

    /// The card's fixed height: the media square with uniform padding.
    static var cardHeight: CGFloat {
        stripCardPadding + mediaSlotHeight + stripCardPadding
    }

    /// The engaged caption's balanced vertical axis — shared by EVERY
    /// post type (video, photo, text), so the caption reads centered in
    /// its band whatever the format: the midpoint of the caption's own
    /// permitted band (`columnTop`…`columnMaxY`), so equal breathing sits
    /// above the text and below it (down to the counters row). A one- or
    /// two-line caption both land balanced — no top-pinned label with the
    /// dead space pooling. Screen-absolute (the cell's caption constrains
    /// against the cell); a pure function of the shared card geometry, so
    /// no format injects a custom margin.
    static func captionBandCenterY(topInset: CGFloat) -> CGFloat {
        let slotMinY = topInset + stripTopPadding + stripCardPadding
        let columnTop = slotMinY + Spacing.xs
        let columnMaxY = captionColumnMaxY(slotMaxY: slotMinY + mediaSlotHeight)
        return (columnTop + columnMaxY) / 2
    }

    /// The engaged-state spring, shared by every leg of the one animation —
    /// and symmetric: the return runs the same envelope, with the footer
    /// crossfade riding inside it in both directions. ONE rhythm: media
    /// morph, caption flight, blur, chrome fades, and both footer alphas
    /// all breathe in this single block.
    static let engageDuration: TimeInterval = 0.45
    static let disengageDuration: TimeInterval = 0.45
    /// The composer's entrance micro-translation: it slides up into place
    /// as it fades, arriving into its stacked seat above the native bar.
    static let composerEntranceOffset: CGFloat = 15

    /// The skeleton density estimate: a DELIBERATE low-ball of the real
    /// skeleton row's height (~48pt with list insets), because the count
    /// is viewport ÷ estimate — the smaller the estimate, the MORE rows,
    /// and over-provisioning is free (the list clips the excess) while
    /// under-provisioning strands blank space above the input bar.
    static let skeletonRowEstimate: CGFloat = 44
    /// How many shimmer rows the first-load snapshot injects: enough to
    /// cover the whole viewport on ANY form factor — SE, Pro Max, iPad —
    /// with zero hardcoded gaps. The fallback covers the pre-layout call
    /// (bounds not yet set): generous enough for every iPhone.
    static func skeletonPlaceholderCount(viewportHeight: CGFloat) -> Int {
        guard viewportHeight > 0 else { return 24 }
        return Int(ceil(viewportHeight / skeletonRowEstimate))
    }

    /// Where the media docks, in cell coordinates: a 1:1 square tile on the
    /// card's left edge, uniformly padded.
    static func mediaSlotFrame(in bounds: CGRect, topInset: CGFloat) -> CGRect {
        guard bounds.height > 0 else { return .zero }
        let card = stripCardFrame(in: bounds, topInset: topInset)
        return CGRect(
            x: Spacing.lg,
            y: card.minY + stripCardPadding,
            width: mediaSlotHeight,
            height: mediaSlotHeight
        )
    }

    /// The center-crop that squares the full-bleed media, in the media
    /// view's own (untransformed) coordinate space: the largest centered
    /// square. Applied as an animated mask, it starts at the full bounds
    /// (no visible crop) and closes to this square as the transform docks
    /// the view — the tile is cropped, never squashed.
    static func mediaCropFrame(in bounds: CGRect) -> CGRect {
        let side = min(bounds.width, bounds.height)
        return CGRect(
            x: (bounds.width - side) / 2,
            y: (bounds.height - side) / 2,
            width: side,
            height: side
        )
    }

    /// The strip's lower boundary — the comments region's upper one.
    static func stripBottom(topInset: CGFloat) -> CGFloat {
        topInset + stripTopPadding + cardHeight + stripBottomPadding
    }

    /// The floating Liquid Glass CARD that carries the strip: the full
    /// post reformatted (header / media+caption / actions), wrapped with
    /// `stripCardPadding` and inset from the screen edges — a distinct
    /// floating surface over the full-height stream, not a wall-to-wall
    /// band. The PRIMARY rect of the engaged geometry: the media slot and
    /// the strip's lower boundary both derive from it.
    static let stripCardCornerRadius: CGFloat = 16
    static let stripCardPadding: CGFloat = Spacing.sm

    static func stripCardFrame(in bounds: CGRect, topInset: CGFloat) -> CGRect {
        let inset = Spacing.lg - stripCardPadding
        return CGRect(
            x: inset,
            y: topInset + stripTopPadding,
            width: bounds.width - inset * 2,
            height: cardHeight
        )
    }

    /// The caption column's hard floor, in cell coordinates: the actions
    /// row is the only reservation at the column's bottom; the caption
    /// stops above it.
    static func captionColumnMaxY(slotMaxY: CGFloat) -> CGFloat {
        slotMaxY - cardActionsHeight - Spacing.xs
    }

    /// How many whole caption lines the column can hold. A LINE cap, not a
    /// height clamp: a height-compressed `UILabel` vertically centers and
    /// clips both edges — only `numberOfLines` yields whole lines with an
    /// honest trailing ellipsis. Never below one (a caption always shows
    /// its first line, whatever Dynamic Type does to the ratio).
    static func captionLineCapacity(columnHeight: CGFloat, lineHeight: CGFloat) -> Int {
        guard lineHeight > 0 else { return 1 }
        return max(1, Int((columnHeight / lineHeight).rounded(.down)))
    }

    /// The comments region's height: everything below the strip, down to
    /// the cell's bottom edge.
    static func commentsRegionHeight(containerHeight: CGFloat, topInset: CGFloat) -> CGFloat {
        max(0, containerHeight - stripBottom(topInset: topInset))
    }

    /// The transform that carries the full-bleed media view into `slot`.
    /// A UNIFORM scale about the view's center plus a recentering translate
    /// — width-based, sized so the center-crop square (`mediaCropFrame`,
    /// whose side is the view's width on portrait pages) lands exactly on
    /// the square slot; the crop is centered, so mapping the view's center
    /// onto the slot's center aligns the two. GPU-composited, no constraint
    /// surgery, exactly reversible to `.identity`.
    static func mediaTransform(bounds: CGRect, slot: CGRect) -> CGAffineTransform {
        guard bounds.width > 0 else { return .identity }
        let scale = slot.width / min(bounds.width, bounds.height)
        return CGAffineTransform(
            translationX: slot.midX - bounds.midX,
            y: slot.midY - bounds.midY
        ).scaledBy(x: scale, y: scale)
    }

    /// Where the header frost's dissolve BEGINS, as a fraction of the
    /// band's height: solid through the nav zone (the screen chrome needs
    /// full frost behind it), fading across the card zone, zero exactly at
    /// the partition line — so a row scrolling up crosses from crisp into
    /// a progressively deepening blur with no geometric seam. Clamped
    /// under 1 so degenerate insets can't invert the ramp.
    static func headerFrostSolidFraction(topInset: CGFloat) -> CGFloat {
        let band = stripBottom(topInset: topInset)
        guard band > 0 else { return 0 }
        return min(0.9, max(0, topInset / band))
    }

    /// The footer frost's ramp: clear at the band's top edge, solid from
    /// this fraction down to the window's bottom — the mirror of the
    /// header's dissolve.
    static let footerFrostSolidFraction: CGFloat = 0.45
    /// How far above the composer's top the footer band begins — the
    /// dissolve's runway. Taller than the old scrim's 16pt lead: a ramp
    /// needs distance to read as a dissolve rather than an edge.
    static let footerFrostLead: CGFloat = 64
}

/// A frosted band whose blur DISSOLVES along its length instead of ending
/// on a hard geometric edge: a `UIVisualEffectView` alpha-masked by a
/// vertical `CAGradientLayer`. The mask must be a VIEW assigned to `mask`
/// (UIKit propagates it through the effect's internal backdrop layers;
/// masking `layer` directly breaks effect rendering), and its frame is
/// re-bound to the bounds every layout pass — the footer band resizes
/// when the keyboard lifts the composer, and a stale mask would shear the
/// ramp. Hit-inert like the hard-edged bands it replaces: the frost
/// frames the stream, it never owns a touch.
final class ProgressiveFrostView: UIVisualEffectView {
    private let fadeMask: GradientView

    /// `maskColors`/`maskLocations` describe the mask's OPACITY ramp
    /// top→bottom: black = full frost, clear = no frost.
    init(maskColors: [UIColor], maskLocations: [NSNumber]) {
        fadeMask = GradientView(colors: maskColors, locations: maskLocations)
        super.init(effect: nil)
        isUserInteractionEnabled = false
        mask = fadeMask
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Re-tunes the ramp's stops (the header band computes its solid
    /// fraction from the frozen insets at install time).
    func setFadeLocations(_ locations: [NSNumber]) {
        fadeMask.setLocations(locations)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fadeMask.frame = bounds
    }
}
