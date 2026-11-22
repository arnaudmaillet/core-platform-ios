import UIKit

/// The full-screen page's bottom scrim ramp (#2175), out of `SnapChromeView`
/// (#2521), which draws it in its `scrimView`.
///
/// ⚠️ IT WAS 68 % OF THE PAGE, from 32 % of the screen down, so that its
/// mid-stop sat behind the reaction band and the subtitle zone (#46). It
/// darkened the middle of every picture to 0.80 of its value and the
/// subject with it — the post looked darker full screen than on its tile.
/// The comment surfaces above the caption no longer get it, by the
/// owner's decision.
///
/// ONE progressive ramp, darker all the way down (the owner, 2026-10-31,
/// on the device: no fade that stops on a plateau), calibrated on
/// TikTok's and Instagram's, measured over a white video (#2175, the
/// owner 2026-11-07: a little darker, the gradient itself imperceptible):
/// - it starts `scrimLead` (48 pt) above the caption block, with a zero
///   slope — no line marks its top — and its first 20 pt stay under 3 %,
///   which the eye reads as nothing (behind the danmaku's lower lane), as
///   the reference's do;
/// - it is never steeper than `scrimSlopeCap` (0.4 % per point, the
///   reference's), and its slope never kinks;
/// - it reaches `scrimTopAlpha` (0.12) at the block's top, about 0.26 at
///   a two-line caption's last line, and about 0.60 at the screen's edge
///   under the toolbar (it was 0.75), easing toward `scrimCeiling` below.
@MainActor
enum SnapPageScrim {
    /// How far above the caption block the ramp begins (#2175, the owner's
    /// option A, 2026-11-07; it was 12 pt, from 2026-11-01): the reference's
    /// darkness at the block's top cannot be reached gently from closer.
    static let scrimLead: CGFloat = 48
    /// The darkness at the caption block's top — its first line: the dark
    /// side of the reference's 0.10–0.12 (the owner: a little darker), which
    /// the app's smaller type (#2149) needs to reach about 0.26 by a two-line
    /// caption's last line at the capped slope.
    static let scrimTopAlpha: CGFloat = 0.12
    /// The steepest the ramp gets, in alpha per point: the reference's.
    static let scrimSlopeCap: CGFloat = 0.004
    /// How far below the block's top the ramp stays at its cap before it
    /// eases toward `scrimCeiling` — past a typical caption and the toolbar.
    static let scrimLinearDepth: CGFloat = 140
    /// What the ramp eases toward far below the block, never reaching it.
    static let scrimCeiling: CGFloat = 0.8
    /// The view's fixed height: the lead and more than any screen below it.
    static let scrimHeight: CGFloat = scrimLead + 1_200

    /// The ramp's darkness `x` points below where it starts (the block's top
    /// is at `scrimLead`). Three pieces, the slope continuous at each joint:
    /// a parabola from a zero slope up to the cap, the cap, then an
    /// exponential ease whose first slope is the cap.
    static func scrimAlpha(at x: CGFloat) -> CGFloat {
        let cap = scrimSlopeCap
        // Where the parabola meets the cap, so the block's top lands on
        // `scrimTopAlpha`: a·x₁² + cap·(lead − x₁) with a = cap / 2x₁.
        let joint = 2 * (cap * scrimLead - scrimTopAlpha) / cap
        guard x > 0 else { return 0 }
        if x <= joint { return cap / (2 * joint) * x * x }
        let easeStart = scrimLead + scrimLinearDepth
        let atJoint = cap * joint / 2
        if x <= easeStart { return atJoint + cap * (x - joint) }
        let atEase = atJoint + cap * (easeStart - joint)
        let room = scrimCeiling - atEase
        return scrimCeiling - room * CGFloat(exp(Double(-(x - easeStart) * cap / room)))
    }

    /// The stops, in points: every 6 pt through the curved start and the
    /// cap — so linear interpolation between stops never shows — then every
    /// 30 pt through the slow ease.
    static let scrimStopPoints: [CGFloat] = {
        let dense = scrimLead + scrimLinearDepth + 24
        var points = Array(stride(from: CGFloat(0), through: dense, by: 6))
        points += Array(stride(from: (points.last ?? 0) + 30, to: scrimHeight, by: 30))
        points.append(scrimHeight)
        return points
    }()
    static let scrimLocations: [NSNumber] = scrimStopPoints.map { NSNumber(value: Double($0 / scrimHeight)) }
    static var scrimColors: [UIColor] {
        scrimStopPoints.map { UIColor.black.withAlphaComponent(scrimAlpha(at: $0)) }
    }
}
