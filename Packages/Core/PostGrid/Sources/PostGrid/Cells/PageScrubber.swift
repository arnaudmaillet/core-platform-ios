import CoreGraphics

/// Where a drag along a page strip puts the page.
///
/// ⚠️ EXTRACTED BECAUSE TWO STRIPS NOW DRAW THE SAME GESTURE — the card's chip
/// of dots and the post screen's full-width bar. The rule is particular enough
/// (a relative anchor, a re-anchor at the ends, a request only on change) that
/// writing it twice would mean two scrubs that feel alike until one of them is
/// touched.
///
/// It holds no view and no gesture: the strip owns those, and hands this the
/// two numbers it has — where the finger is, and how many pages there are.
public struct PageScrubber {
    /// How far the finger travels for one page.
    ///
    /// The chip's is a dot's slot; the bar's is a segment's, which is a
    /// function of its width. So each strip tracks the finger at its own scale
    /// and both feel like the thing they are drawn as.
    public var pointsPerPage: CGFloat

    private var anchorX: CGFloat = 0
    private var anchorPage = 0
    private var lastRequestedPage: Int?

    public init(pointsPerPage: CGFloat) {
        self.pointsPerPage = pointsPerPage
    }

    /// ⚠️ THE PAGE YOU ARE ON IS WHERE THE DRAG STARTS FROM, wherever the
    /// finger lands.
    ///
    /// The touch used to be read ABSOLUTELY — the strip divided into as many
    /// bands as there are pages, and wherever you pressed is the page you got.
    /// Which meant putting a finger on the middle of the chip teleported a
    /// twelve-page post to page six before the drag had moved at all. The chip
    /// looked like a scrubber and behaved like a row of targets.
    ///
    /// So the touch-down point is an ORIGIN, not a coordinate: it pins the
    /// current page, and only movement from there asks for anything.
    public mutating func begin(atX x: CGFloat, page: Int) {
        anchorX = x
        anchorPage = page
        lastRequestedPage = page
    }

    /// The page the finger is asking for now — `nil` when it is still asking
    /// for the one it last asked for.
    ///
    /// Only when it CHANGES, because `.changed` fires on every touch move and
    /// the host's answer to a page request is to scroll a carousel.
    public mutating func page(draggedTo x: CGFloat, pageCount: Int) -> Int? {
        guard pageCount > 0, pointsPerPage > 0 else { return nil }
        let travelled = Int(((x - anchorX) / pointsPerPage).rounded())
        let raw = anchorPage + travelled
        let page = min(max(raw, 0), pageCount - 1)
        // ⚠️ RE-ANCHOR AT THE ENDS, or the gesture goes numb.
        //
        // Drag twenty pages past the last one and `raw` is twenty out of range.
        // Without this the finger would have to travel all twenty back before
        // the strip moved again — the control would feel stuck exactly when the
        // viewer is trying to correct an overshoot. Pinning the anchor to the
        // edge means the way back responds on the first slot.
        if raw != page {
            anchorPage = page
            anchorX = x
        }
        guard page != lastRequestedPage else { return nil }
        lastRequestedPage = page
        return page
    }
}
