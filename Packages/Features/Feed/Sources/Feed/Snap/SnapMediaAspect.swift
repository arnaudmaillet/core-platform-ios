import CoreGraphics
import PostGrid

/// The fullscreen feed's framing rule: which pictures fill the page and which
/// are shown whole — the product decision of 2026-09-27, in one place.
///
/// On the picture's width / height `r`:
///
/// | r                | framing        | typical media                   |
/// |------------------|----------------|---------------------------------|
/// | r ≤ 2:3          | `.fill`        | 9:16 clips, 2:3 photos, stories |
/// | 2:3 < r ≤ 1:1    | `.fitBlurred`  | 3:4, 4:5, square                |
/// | r > 1:1          | `.fitBlack`    | landscape                       |
///
/// A tall picture loses only a sliver to the crop and fills the screen the way
/// a vertical feed is expected to. Between 2:3 and square the crop starts
/// eating the subject, so the picture is shown whole — and the bands, which
/// are short, are filled by a blurred extension of the picture itself so the
/// page still reads as one full-screen image. Past square the bands are
/// taller than the picture, and a blur that big stops reading as an extension
/// of anything: plain black, like any landscape video player.
///
/// ⚠️ THE BOUNDARIES ARE EXACT, deliberately — no tolerance. A tolerance is a
/// second rule nobody wrote down, and the pictures sitting on a boundary are
/// exact in practice: a 2:3 photo is 1080×1620 (`r` is then bit-for-bit
/// `2/3`, and fills), a square is 1080×1080. The price is that a picture one
/// pixel off square on the wide side is treated as landscape; that is the rule
/// as specified, and pinned at 1.001 by `SnapMediaAspectTests`.
///
/// ⚠️ THE ASPECT IS THE CURRENT PAGE'S PICTURE, measured when possible: a
/// photo's pixel size, a clip's natural size, and only before either exists
/// the shape the post declared. A collection decides per page
/// (`MediaCarouselView.pageFraming`), since its pages need not agree.
enum SnapMediaAspect {
    /// The tallest shape that is still shown whole — 2:3.
    static let fillLimit: CGFloat = 2.0 / 3.0
    /// The widest shape that still gets the blurred extension — 1:1.
    static let blurLimit: CGFloat = 1

    /// The framing for a picture of width / height `ratio`. A degenerate ratio
    /// (zero, negative, not finite) fills: there is no picture to fit.
    static func presentation(forAspect ratio: CGFloat) -> MediaFraming {
        guard ratio > 0, ratio.isFinite else { return .fill }
        if ratio <= fillLimit { return .fill }
        if ratio <= blurLimit { return .fitBlurred }
        return .fitBlack
    }

    /// The framing for a picture of `size` (pixels or points — only the ratio
    /// is read).
    static func presentation(for size: CGSize) -> MediaFraming {
        guard size.height > 0 else { return .fill }
        return presentation(forAspect: size.width / size.height)
    }
}
