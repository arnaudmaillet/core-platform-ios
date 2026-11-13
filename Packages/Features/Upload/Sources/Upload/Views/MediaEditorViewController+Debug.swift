import AVFoundation
import DesignSystem
import MediaPlayback
import UIKit

// The editor's test hooks (#2388, out of the editor's file), DEBUG only.

#if DEBUG
extension MediaEditorViewController {
    /// Internal for tests: how many pages the canvas holds.
    var debugPageCount: Int { dataSource.snapshot().numberOfItems }
    /// Internal for tests: what the fill/fit button currently offers.
    /// Internal for tests: what the fill/fit glyph offers — it stands in the
    /// crop tools now, not in the header.
    var debugFitActionName: String? { cropTools.debugFitLabel }
    /// Internal for tests: the path the fill/fit button takes, without a bar to tap.
    func debugTapFit() { toggleFit() }

    /// Internal for tests: the dissolve behind the chrome, to measure where it
    /// begins, how far it reaches, and which side of the band it draws on.
    var debugBackdrop: UIView { backdrop }

    /// Internal for tests: the indicator, whose position is what the band moves.
    var debugPageDots: UIView { pageDots }

    /// Internal for tests: the categories the strip spells.
    var debugCategoryTitles: [String] { categories.map(\.title) }
    /// Internal for tests: which category is open, nil while the strip is
    /// neutral.
    var debugSelectedCategory: String? { selectedCategory }
    /// Internal for tests: the strip in the bar, to read what it is wearing.
    var debugCategoryBar: IconSelectorBar { categoryBar }
    /// Internal for tests: chooses a category BY NAME, as the strip's `select`
    /// would. ⚠️ **NEVER BY POSITION** — a clip's list and a photograph's put
    /// the same category at different indices, and a test that picked "3"
    /// would open Stickers on one and Filters on the other.
    func debugChoose(_ title: String) {
        guard let index = categories.firstIndex(where: { $0.title == title }) else {
            preconditionFailure("\(title) is not offered here: \(categories.map(\.title))")
        }
        categoryBar.select(index)
    }
    /// Internal for tests: taps a category BY NAME, the way a finger would —
    /// a tap on the chosen one is a reselect.
    func debugTapCategory(_ title: String) {
        guard let index = categories.firstIndex(where: { $0.title == title }) else {
            preconditionFailure("\(title) is not offered here: \(categories.map(\.title))")
        }
        categoryBar.debugTap(index)
    }
    /// Internal for tests: the width each strip is being held to, or nil where
    /// the rule is not being applied.
    var debugStripWidths: (leading: CGFloat, trailing: CGFloat)? {
        guard categoryBarWidth.isActive else { return nil }
        let leading = isTimelineShowing
            ? actionBarWidth.constant
            : Self.wantedWidth(of: soundPill)
        return (leading, categoryBarWidth.constant)
    }

    /// Internal for tests: the end of a scrub, through the very routine the
    /// track's own callback calls.
    func debugEndScrub() { scrubbing(false) }

    /// Internal for tests: one beat of the follower, through the very routine the
    /// display link calls rather than alongside it.
    func debugFollowTick() { followPlayhead() }

    /// Internal for tests: a tap on the picture, through the very routine the
    /// recogniser calls.
    func debugTapMedia() { mediaTapped() }

    /// Internal for tests: whether the canvas actually carries the tap.
    var debugMediaTapIsAttached: Bool {
        canvas.gestureRecognizers?.contains(mediaTap) ?? false
    }

    /// Internal for tests: what the track is waiting for, if anything.
    var debugHandover: MediaTimelining.Handover { handover }
    /// Internal for tests: whether a load is on its way to the preview.
    var debugPreviewIsPending: Bool { previewPending }
    /// Internal for tests: whether the preview is showing the file as shot for a
    /// held handle.
    var debugPreviewIsAiming: Bool { previewSubject?.aiming ?? false }
    /// Internal for tests: the arrangement the screen believes the preview plays.
    var debugPreviewTimeline: MediaTimeline? { previewSubject?.timeline }
    /// Internal for tests: the cut whose transition is being chosen.
    var debugTransitionSeam: Int? { rowFocus.transition?.seam }
    /// Internal for tests: the stretch the screen believes the item loops.
    var debugPreviewLoop: ClosedRange<Double>? { previewSubject?.loop }
    /// Internal for tests: a tap on the picture, through the routine the
    /// recogniser calls.
    func debugTapTheMedia() { mediaTapped() }
    /// Internal for tests: the play/pause glyph, and every state it flashed.
    var debugPlaybackFlashes: [Bool] { playbackFlash.debugFlashes }
    /// Internal for tests: the path "Next" takes, without a bar to tap.
    func debugTapNext() { goNext() }
    /// Internal for the +QA hooks: what choosing a category does, for an index
    /// the strip already rests on (`select(_:)` announces only a change).
    func debugCategoryChanged() { categoryChanged() }
    /// Internal for the +QA hooks: the `+` on a cut, through its own routine.
    func debugOpenTransitions(atSeam seam: Int) { openTransitions(atSeam: seam) }
    /// Internal for tests: the scissors, through the routine the bar calls.
    func debugSplitAtTheNeedle() { splitAtTheNeedle() }
    /// Internal for tests: the undo arrow, through the routine it actually calls.
    func debugTapUndo() { stepBack() }
    func debugTapRedo() { stepForward() }
    /// Internal for tests: the two arrows, to read what they offer.
    var debugUndoItem: UIBarButtonItem { undoItem }
    var debugRedoItem: UIBarButtonItem { redoItem }

    /// Internal for tests: whether the screen is in crop mode.
    var debugIsCropping: Bool { isCropping }
    /// Internal for tests: the editing surface, to drive a drag without a finger.
    var debugCropSurface: MediaCropSurfaceView { cropSurface }
    /// Internal for tests: the tools in the band, to turn the dial without one.
    var debugCropTools: MediaCropToolsView { cropTools }
    /// Internal for tests: whether anything at all is stored for an item — the
    /// difference between "chose the default" and "never chose".
    func debugHasEdits(for id: String) -> Bool { session.hasEdits(for: id) }

    /// Internal for tests: the black the crop tools stand on, if it is up at all.
    var debugCropChrome: UIView? { cropChrome.superview == nil ? nil : cropChrome }

    /// Internal for tests: where the page indicator sits, which is the foot of a
    /// fitted picture's window.
    var debugPageDotsTop: CGFloat { pageDots.frame.minY }

    /// Internal for tests: the path the crop's own reset takes, without a
    /// control to tap. It is the crop tools' now — the header walks the
    /// author's history instead.
    func debugTapResetCrop() { resetCrop() }
    /// Internal for tests: whether the bar is offering the two arrows, and on
    /// which side.
    var debugBarOffersTheArrows: Bool {
        let items = navigationItem.rightBarButtonItems ?? []
        return items.contains { $0 === undoItem } && items.contains { $0 === redoItem }
    }

    /// Internal for tests: how many of the stack's pans are currently suspended.
    var debugSuspendedPans: Int { suspendedPans.count }
    /// Internal for tests: the path the strip's touch probe takes.
    func debugSetTouchingStrip(_ isTouching: Bool) {
        isTouchingStrip = isTouching
        updateStackGestures()
    }
    /// Internal for tests: whether the surface is in the hierarchy at all — the
    /// half of "left crop mode" that a flag cannot answer.
    var debugCropSurfaceIsShowing: Bool { cropSurface.superview != nil }
}
#endif
