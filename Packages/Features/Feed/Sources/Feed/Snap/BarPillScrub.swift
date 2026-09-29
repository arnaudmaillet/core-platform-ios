import CoreGraphics

/// Pure scroll math for the feed's two bar pills (the author pill above, the
/// audio capsule below): how blurred they are at a given scroll position, and
/// WHOSE content they draw — so the change of post rides the finger instead of
/// landing at the settle.
///
/// The position is the pager's offset in pages (`contentOffset.y / page
/// height`): between pages `i` and `i + 1`, the fractional part `p` is how
/// much of the screen page `i + 1` covers. Along `p` —
///
///     p     0 ─── 0.3 ─────── 0.48 ─ 0.5 ─ 0.52 ─────── 0.7 ─── 1
///     blur  0      0 ↗ rising ↗  1     1     1  ↘ falling ↘ 0      0
///     shows          page i         │ swap │        page i + 1
///
/// — sharp until the page being left is 30% off screen, fully blurred while
/// the two pages split the screen, sharp again once the incoming page covers
/// 70% of it. The curve depends on `p` alone, so scrolling UP runs the same
/// ramps mirrored: the page coming in from above covers `1 - p`.
///
/// ⚠️ THE SWAP HAS HYSTERESIS, AND THE PLATEAU IS WHY IT IS INVISIBLE. The
/// content follows the page covering most of the screen, but only once that
/// page is `hysteresis` past the midpoint — a finger held at 50% jittering by
/// a point would otherwise swap the pills back and forth every frame. The
/// blur holds at its full strength across that band (0.48…0.52), so the swap
/// is only ever made while nothing sharp is showing, in either direction.
///
/// Kept free of UIKit so the contract is unit-tested without a scroll view
/// (`BarPillScrubTests`).
struct BarPillScrub: Equatable {
    /// How much of the screen the incoming page covers when the blur starts
    /// rising — the outgoing page 30% off screen.
    static let blurStart: CGFloat = 0.3
    /// Where the content changes hands: the incoming page covers half.
    static let swapPoint: CGFloat = 0.5
    /// How much of the screen the incoming page covers when the blur is gone.
    static let blurEnd: CGFloat = 0.7
    /// How far past the midpoint a page has to be before the pills show it.
    static let hysteresis: CGFloat = 0.02

    /// The two pages the viewport straddles, and how blurred the pills are.
    struct Frame: Equatable {
        /// The upper page of the pair; the lower one is `upper + 1`.
        var upper: Int
        /// 0 (sharp) … 1 (fully blurred).
        var blur: CGFloat
    }

    /// The blur for an incoming page covering `coverage` of the screen.
    static func blur(coverage: CGFloat) -> CGFloat {
        let p = min(max(coverage, 0), 1)
        let ramp = swapPoint - hysteresis - blurStart
        if p <= blurStart || p >= blurEnd { return 0 }
        if p < swapPoint - hysteresis { return (p - blurStart) / ramp }
        if p > swapPoint + hysteresis { return (blurEnd - p) / ramp }
        return 1
    }

    /// The pair of pages at `position` (in pages) and their blur — nil when
    /// the viewport is not between two real pages: resting exactly on one, or
    /// overscrolled past either end of the feed (a bounce, the paging
    /// footer), where there is nothing to change to.
    static func frame(position: CGFloat, itemCount: Int) -> Frame? {
        guard position.isFinite, itemCount > 1 else { return nil }
        let upper = Int(position.rounded(.down))
        guard upper >= 0, upper + 1 < itemCount else { return nil }
        return Frame(upper: upper, blur: blur(coverage: position - CGFloat(upper)))
    }

    /// The page whose content the pills draw; nil until a page has settled.
    private(set) var shownIndex: Int?

    /// The pills now draw `index` — a settle put its content there.
    mutating func settle(at index: Int?) {
        shownIndex = index
    }

    /// Follows the scroll to `position` (in pages). Returns the page whose
    /// content the pills should switch to, when that has just changed — at
    /// most one per call, and the one covering most of the screen, even when
    /// a jump passed several.
    mutating func update(position: CGFloat, itemCount: Int) -> Int? {
        guard let shown = shownIndex, position.isFinite, itemCount > 0 else { return nil }
        let nearest = min(max(Int(position.rounded()), 0), itemCount - 1)
        guard nearest != shown,
              abs(position - CGFloat(shown)) > Self.swapPoint + Self.hysteresis else { return nil }
        shownIndex = nearest
        return nearest
    }
}
