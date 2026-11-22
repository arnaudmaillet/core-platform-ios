import DesignSystem
import ThreadKit
import UIKit

/// Where the full-screen page's caption, page strip and action column stand
/// over the bottom bar (#2252, #2301, #2326) — out of `SnapChromeView` (#2521),
/// derived from `SnapActionColumn`'s numbers.
@MainActor
enum SnapChromeGeometry {
    /// Where the page strip's line is centred, below the margins line
    /// (#2252, the owner 2026-11-10): halfway between the bottom of the
    /// caption's letters and the top of the toolbar's glass.
    ///
    /// ⚠️ IT RESERVES NO HEIGHT. The caption stands on the cover's line on
    /// every format (`captionOnCoverLine`); the strip lies in the gap that
    /// was already there between the caption and the bar, so a video or a
    /// carousel lays out exactly as a single photo does. Before #2252 the
    /// caption sat 22 pt higher over a strip, and everything stacked on it
    /// jumped between posts.
    ///
    /// The letters' bottom is the caption's last baseline: its frame's
    /// bottom, less what its line box keeps under the baseline
    /// (`captionLetterDrop`). Expected (the owner's measures, the issue):
    /// about 10 pt either side of the line over the toolbar.
    ///
    /// ⚠️ SUPERSEDED BY #2301 (the owner, 2026-11-11): the strip is no longer
    /// centred. Its line stands `SnapActionColumn.stripAboveGlass` (10 pt)
    /// over the bar's glass, and the caption rises instead
    /// (`coverLineLift`), its letters `captionAboveStrip` (16 pt) above it.
    static func pageBarCenterOffset(breathApplied: Bool = true) -> CGFloat {
        let glass: CGFloat = SnapActionColumn.glassBelowMargins(breathApplied: breathApplied)
        return glass - SnapActionColumn.stripAboveGlass - SnapMediaPageBarView.thickness / 2
    }

    /// ⚠️ ONE SEAT FOR EVERY MEDIA POST, RAISED (#2301): how far the
    /// caption's bottom — and with it the caption floor and the band —
    /// stands above where #2252 put it (`inputRestingGap` over the margins),
    /// so the caption's letters end `captionAboveStrip` over the strip's top,
    /// strip or not. Stated from the glass: about 6 pt over the toolbar.
    ///
    /// The column rises too since #2326 (`columnLineLift`), which reverses
    /// #2301's option (c), where it stayed on the composer's line.
    static func coverLineLift(breathApplied: Bool = true) -> CGFloat {
        let lettersAboveMargins: CGFloat = captionLettersAboveMargins(breathApplied: breathApplied)
        let captionBottomAboveMargins: CGFloat = lettersAboveMargins - captionLetterDrop
        return max(0, captionBottomAboveMargins - SnapActionColumn.inputRestingGap)
    }

    /// Where the caption's letters end above the margins line on a media
    /// page (#2301): `captionAboveStrip` over the strip's top, which stands
    /// `stripAboveGlass` over the bar's glass.
    static func captionLettersAboveMargins(breathApplied: Bool = true) -> CGFloat {
        let glass: CGFloat = SnapActionColumn.glassBelowMargins(breathApplied: breathApplied)
        return SnapActionColumn.stripAboveGlass + SnapMediaPageBarView.thickness
            + SnapActionColumn.captionAboveStrip - glass
    }

    /// ⚠️ THE COLUMN ON THE CAPTION'S LINE (#2326, the owner 2026-11-11,
    /// reversing #2301's option c): how far the whole action column — the
    /// sound cover or the share bubble at its bottom, the like pill and the
    /// emote rail over it — stands above the composer's
    /// line (`inputRestingGap`) on a media page at rest. Its bottom lands on
    /// the caption's letters' line, `captionAboveStrip` (16 pt) over the
    /// strip's top: 10 pt over the toolbar.
    ///
    /// This is the cover line's lift (`coverLineLift`) plus the caption's
    /// letter drop: the caption's frame keeps what its line box holds under
    /// the baseline, the column has nothing under its bottom.
    ///
    /// ⚠️ THE OTHER POSITION IS THE COMPOSER'S LINE. The engaged composer's
    /// stake and rail stand on the like pill and the sound bubble (#669,
    /// #680) at `inputRestingGap`; the column glides down to it inside the
    /// comments' opening, driven by the opening's own progress, and back up
    /// inside the close (`applyColumnGlide`).
    static func columnLineLift(breathApplied: Bool = true) -> CGFloat {
        let lettersAboveMargins: CGFloat = captionLettersAboveMargins(breathApplied: breathApplied)
        return max(0, lettersAboveMargins - SnapActionColumn.inputRestingGap)
    }

    /// What the caption's line box keeps under its baseline: the bottom of
    /// its letters stands this far above the label's bottom. Every line is
    /// locked to the caption font's line height (`captionParagraphStyle`),
    /// so it is that height less the font's ascender. Font-derived: it
    /// follows Dynamic Type.
    static var captionLetterDrop: CGFloat {
        let font = UIFont.appFont(forTextStyle: SnapCaptionComposer.CaptionRegister.textStyle)
        return max(font.lineHeight - font.ascender, 0)
    }

    /// Two caption lines, rounded up to `scale`'s pixels. Font-derived: it
    /// follows Dynamic Type.
    static func captionBlockHeight(scale: CGFloat) -> CGFloat {
        let twoLines: CGFloat = 2 * UIFont.appFont(forTextStyle: SnapCaptionComposer.CaptionRegister.textStyle).lineHeight
        return (twoLines * scale).rounded(.up) / scale
    }

    /// The caption's locked box height: `SnapActionColumn.captionFloorHeight`
    /// (#2380), which the column stands on.
    static var captionFloorHeight: CGFloat { SnapActionColumn.captionFloorHeight }
}
