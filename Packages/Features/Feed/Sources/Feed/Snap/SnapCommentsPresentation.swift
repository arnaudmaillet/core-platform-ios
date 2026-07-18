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
    /// engaged screen belongs to the comments). The media still shrinks as
    /// a uniform scale (no distortion) — squareness comes from an animated
    /// center-crop mask (`mediaCropFrame`), so the docked tile re-crops the
    /// full-bleed content rather than squashing it.
    static let mediaSlotHeight: CGFloat = 128
    /// The docked media's visual corner radius (compensated for the
    /// transform's scale when applied to the full-size layer).
    static let mediaCornerRadius: CGFloat = 16
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
    /// repost, save.
    static let cardActionsHeight: CGFloat = 28
    /// The music/attribution line's reserved height, directly above the
    /// actions row (caption text must stop above both).
    static let cardMusicLineHeight: CGFloat = 18
    /// The card content's entrance micro-translation — the rows rise into
    /// place as they fade in, the composer-entrance recipe at card scale.
    static let cardContentEntranceOffset: CGFloat = 12

    /// The card's fixed height: the media square with uniform padding.
    static var cardHeight: CGFloat {
        stripCardPadding + mediaSlotHeight + stripCardPadding
    }

    /// The engaged-state spring, shared by every leg of the one animation —
    /// and symmetric: the return runs the same envelope, with the footer
    /// crossfade riding inside it in both directions. ONE rhythm: media
    /// morph, caption flight, blur, chrome fades, and both footer alphas
    /// all breathe in this single block.
    static let engageDuration: TimeInterval = 0.45
    static let disengageDuration: TimeInterval = 0.45
    /// The composer's entrance micro-translation: it slides up into place
    /// as it fades, so the footer crossfade reads as an arrival, not a
    /// ghosting double-exposure.
    static let composerEntranceOffset: CGFloat = 15
    /// How far the native floating bar's container translates DOWN to carry
    /// its Liquid Glass platters fully out of the viewport (bar band ≈90pt
    /// tall above the home indicator; 160 clears it with margin). A pure
    /// transform: platter glass cannot interpolate alpha and pops on
    /// visibility flips, but every layer interpolates a translation.
    static let nativeFooterExitOffset: CGFloat = 160

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

    /// The caption column's hard floor, in cell coordinates: the column
    /// stacks bottom-up from the slot's bottom edge — actions row first,
    /// then the music line when the post carries one — and the caption
    /// stops above whatever is reserved.
    static func captionColumnMaxY(slotMaxY: CGFloat, hasAudioLine: Bool) -> CGFloat {
        slotMaxY - cardActionsHeight - Spacing.xs
            - (hasAudioLine ? cardMusicLineHeight + Spacing.xs : 0)
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

    /// The caption's flight transform: maps a label SETTLED at `finalFrame`
    /// (its engaged, slot-side home) back onto `sourceFrame`'s top-left (the
    /// chrome caption's full-width home), scaled up by the type ratio — so
    /// animating this to `.identity` reads as the caption physically
    /// traveling and re-setting into the strip, not teleporting. Top-left
    /// anchored (about the default center anchor, compensated): text hangs
    /// from its first glyph, so that corner is the one the eye tracks.
    /// True glyph reflow can't be interpolated — the label wears its
    /// destination wrap for the whole flight; motion carries the swap.
    static func captionFlightTransform(
        finalFrame: CGRect, sourceFrame: CGRect, scale: CGFloat
    ) -> CGAffineTransform {
        let dx = sourceFrame.minX - (finalFrame.midX - finalFrame.width * scale / 2)
        let dy = sourceFrame.minY - (finalFrame.midY - finalFrame.height * scale / 2)
        return CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
    }

    /// The flight's type-scale: the chrome caption's body tier over the
    /// engaged caption's subheadline tier, resolved at the current Dynamic
    /// Type size.
    static func captionFlightScale() -> CGFloat {
        let body = UIFont.preferredFont(forTextStyle: .body).pointSize
        let subhead = UIFont.preferredFont(forTextStyle: .subheadline).pointSize
        return subhead > 0 ? body / subhead : 1
    }
}
