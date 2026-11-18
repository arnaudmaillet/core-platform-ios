import UIKit

/// How a destination page draws its picture when it does NOT fill the page —
/// the description a hero needs to fly the page's own composition instead of
/// a full-screen crop of the picture.
///
/// A page that fills answers nil (`ZoomTransitionDestination.zoomPageFraming`)
/// and every flight is exactly the flight that existed before pages could fit:
/// one card, aspect-fill of its own bounds, landing on the page rect.
///
/// A page that FITS shows the whole picture, centred, on a backdrop that fills
/// the rest of the page. The flight then flies a PAGE WINDOW
/// (`ZoomPageWindowCard`): page-shaped at the page end, with this backdrop and
/// the picture already fitted inside it — the composition itself is what
/// animates, never the picture's bare rect with bands painted around it
/// afterwards. (The fitted-rect hero of #255 was rejected on sight: a small
/// landscape rectangle crossing the screen reads as a thumbnail, not as the
/// page the viewer is opening.)
public struct ZoomPageFraming {
    /// What fills the page around the fitted picture.
    public enum Backdrop {
        /// Plain black bands — a landscape picture.
        case black
        /// A picture, already prepared by the page exactly as the page draws
        /// it (for a feed page: a stretched, heavily blurred, darkened copy of
        /// the media). Drawn aspect-FILL of the window at every size.
        ///
        /// ⚠️ THE PAGE'S OWN PIXELS, not a second rendition of them. The flight
        /// hands over to the page (and the page to the flight) at full screen,
        /// and two blurs of the same photograph computed two ways differ by
        /// exactly the amount a viewer sees as a flash at the hand-over.
        case picture(UIImage)
    }

    /// The picture's shape (width : height) — what the page fits.
    public let mediaAspect: CGSize
    public let backdrop: Backdrop

    /// Nil for a degenerate aspect: there is no picture to fit, and the caller
    /// flies the filling hero rather than a window around nothing.
    public init?(mediaAspect: CGSize, backdrop: Backdrop) {
        guard mediaAspect.width > 0, mediaAspect.height > 0,
              mediaAspect.width.isFinite, mediaAspect.height.isFinite
        else { return nil }
        self.mediaAspect = mediaAspect
        self.backdrop = backdrop
    }
}
