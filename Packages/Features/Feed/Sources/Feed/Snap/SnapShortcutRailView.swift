import CoreModels
import DesignSystem
import UIKit

/// The vertical shortcut wheel: a right-edge rail of quick-react shortcuts,
/// spanning from the comment ticker's top edge up to the navigation bar. The
/// payload is temporary — randomized SF Symbol bubbles standing in for the
/// user's favorite react-GIFs — but the geometry and interaction contract are
/// the real feature: icons only, no text or counts.
///
/// # Wheel
/// A plain vertical `UIScrollView` (its own delegate), not a collection view:
/// the payload is a handful of fixed-size bubbles with no reuse pressure, and
/// frames are laid manually (the hot-cell doctrine — no Auto Layout inside a
/// surface that moves every frame). `decelerationRate = .fast` plus detent
/// snapping in `scrollViewWillEndDragging` gives the wheel feel: releases
/// settle with bubbles on the step grid, never straddling the clip edge.
///
/// # Resting window
/// At rest exactly `restingIconCount` bubbles show, docked at the rail's
/// BOTTOM (on the subtitle zone's horizon), with the rest clipped below the
/// frame's bottom edge. This is pure contentInset arithmetic: the rail's
/// frame spans the full ticker→nav-bar band (so the whole strip is grabbable
/// and revealed icons have somewhere to go), `contentInset.top` pads the
/// scroll range by `frame height − resting window`, and the rest offset is
/// `-contentInset.top`. Swiping up walks the hidden icons in from the bottom
/// edge; the top clamp bottom-aligns the whole column, filling the rail
/// toward the nav bar.
///
/// # Feed arbitration
/// Nested same-axis scrolling: a touch that lands on the rail belongs to the
/// rail — UIKit's inner-scroll-view precedence keeps the vertical pager still
/// while the wheel spins, and edge overshoot rubber-bands inside the rail
/// instead of handing off a page transition. `gestureRecognizerShouldBegin`
/// mirrors the ticker's axis test in the other direction: only vertically
/// dominant drags begin, so a rightward slide-to-pop that starts on the rail
/// stays with the navigation gesture. Taps are the cell's arbitration seam:
/// the chrome declares this rail an `interactionRoot`, so touches here never
/// toggle playback.
///
/// # Flight replica
/// Populated from `configure` (static content, like the caption), so the
/// transition's inert replica shows the same rail. The payload is therefore
/// seeded per post id — "randomized" across posts, but deterministic within
/// a launch — so the live cell and its flight replica can never disagree.
/// (A user-scrolled wheel snaps back to rest in the replica; acceptable while
/// the payload is placeholder.)
final class SnapShortcutRailView: UIScrollView {
    /// The feed's bubble invariant (nav/toolbar circles are 36pt).
    static let iconDiameter: CGFloat = 36
    static let iconSpacing: CGFloat = Spacing.md
    /// The rail is exactly one bubble wide; the frame is the hit area.
    static let railWidth: CGFloat = iconDiameter
    /// How many bubbles the resting window shows.
    static let restingIconCount = 3
    /// One detent: a bubble plus its gap.
    static var step: CGFloat { iconDiameter + iconSpacing }
    /// The resting window's height: exactly `restingIconCount` bubbles.
    static var restingWindowHeight: CGFloat {
        CGFloat(restingIconCount) * iconDiameter + CGFloat(restingIconCount - 1) * iconSpacing
    }

    private var icons: [UIButton] = []
    private var lastLaidOutSize: CGSize = .zero
    private var needsContentRebuild = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        // The cell sits under the transparent nav bar; ambient inset
        // adjustment would shove the wheel's scroll range around.
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        // The wheel always answers a swipe with the native rubber-band,
        // even when the payload is too small to reveal anything.
        alwaysBounceVertical = true
        clipsToBounds = true
        scrollsToTop = false // the status-bar tap belongs to the feed
        isHidden = true
        accessibilityIdentifier = "shortcut-rail"
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Vertical intent only — the ticker's axis test, mirrored: horizontal
    /// drags starting on the rail stay with the timeline slide-to-pop.
    /// Translation, NOT velocity: UIKit consults this for the scroll view's
    /// own pan on early touch samples where velocity is still zero — a
    /// velocity test reads those as "not vertical" and freezes the wheel
    /// for the whole touch. (The ticker can test velocity because its pan
    /// is a standalone recognizer, only consulted after real movement.)
    /// A directionless sample stays with the wheel: the rail is a dead
    /// zone for other pans either way, and refusing here would kill the
    /// gesture outright.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        let translation = panGestureRecognizer.translation(in: self)
        guard translation != .zero else { return true }
        return abs(translation.y) > abs(translation.x)
    }

    // MARK: - Content

    /// Replaces the wheel's shortcuts. Empty (text-only post, or a reset
    /// cell awaiting configure) hides the rail entirely — the same
    /// empty-hides-the-surface doctrine as the ticker and subtitle zone.
    /// Always returns the wheel to its resting window.
    func setSymbols(_ names: [String]) {
        for icon in icons { icon.removeFromSuperview() }
        icons = names.map(Self.makeIconBubble)
        for icon in icons { addSubview(icon) }
        isHidden = names.isEmpty
        needsContentRebuild = true
        setNeedsLayout()
    }

    /// Back to the resting window (cell reuse).
    func reset() {
        setSymbols([])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // layoutSubviews fires on every scrolled frame (bounds.origin moves);
        // geometry only changes when the size or the payload does.
        guard needsContentRebuild || bounds.size != lastLaidOutSize else { return }
        needsContentRebuild = false
        lastLaidOutSize = bounds.size
        rebuildGeometry()
    }

    private func rebuildGeometry() {
        let diameter = Self.iconDiameter
        let x = (bounds.width - diameter) / 2
        for (index, icon) in icons.enumerated() {
            icon.frame = CGRect(x: x, y: CGFloat(index) * Self.step, width: diameter, height: diameter)
        }
        let contentHeight = icons.isEmpty
            ? 0
            : CGFloat(icons.count) * diameter + CGFloat(icons.count - 1) * Self.iconSpacing
        contentSize = CGSize(width: bounds.width, height: contentHeight)
        // The rest offset parks icon 0 at the top of the resting window —
        // everything past `restingIconCount` sits clipped below the frame.
        contentInset = UIEdgeInsets(
            top: max(0, bounds.height - Self.restingWindowHeight),
            left: 0, bottom: 0, right: 0
        )
        contentOffset = CGPoint(x: 0, y: -contentInset.top)
    }

    // MARK: - Detents

    /// Snaps a proposed deceleration target onto the step grid measured from
    /// the rest offset, clamped to the scrollable range. The top clamp
    /// (`maxOffset`, the bottom-aligned full column) is deliberately allowed
    /// off-grid: the fully revealed wheel aligns to the rail's frame, not to
    /// a detent. Pure + static so the arithmetic is unit-testable.
    static func snappedTarget(
        proposed: CGFloat, restOffset: CGFloat, step: CGFloat, maxOffset: CGFloat
    ) -> CGFloat {
        let snapped = restOffset + (step > 0 ? (proposed - restOffset) / step : 0).rounded() * step
        return min(max(snapped, restOffset), max(maxOffset, restOffset))
    }

    // MARK: - Placeholder payload

    /// Temporary stand-ins for the react-GIF shortcuts. Seeded by post id
    /// (the ticker builder's RNG + hash, reused): randomized across posts,
    /// but the live cell and its flight replica always draw the same wheel.
    static func placeholderPayload(for id: PostID) -> [String] {
        var generator = SplitMix64(seed: CommentTickerBuilder.fnv1a(id.rawValue))
        return symbolPool.shuffled(using: &generator)
    }

    /// Reaction-shaped symbols only — the wheel reads as "react", not "menu".
    static let symbolPool = [
        "heart.fill", "flame.fill", "hands.clap.fill", "face.smiling.fill",
        "bolt.fill", "star.fill", "party.popper.fill", "hand.thumbsup.fill",
        "sparkles",
    ]

    /// One shortcut bubble: the subtitle pill's flat translucent black (a
    /// direct composite — nine backdrop blurs on a scrolling surface would
    /// not survive device triage), the toolbar's symbol metrics. A `UIButton`
    /// so the cell's tap arbitration sees a `UIControl`; tap behavior itself
    /// arrives with the real GIF payload.
    private static func makeIconBubble(systemName: String) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: systemName)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        config.baseForegroundColor = .white
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        button.layer.backgroundColor = UIColor.black.withAlphaComponent(0.45).cgColor
        button.layer.cornerRadius = iconDiameter / 2
        button.layer.cornerCurve = .continuous
        return button
    }

    // MARK: - Test seams

    /// Bubbles currently inside the visible window (edge-touching a clip
    /// boundary does not count). Internal so tests can pin the resting
    /// window to exactly `restingIconCount`.
    var visibleIconCount: Int {
        let window = CGRect(origin: contentOffset, size: bounds.size)
        return icons.count(where: { $0.frame.intersects(window) })
    }
}

// MARK: - Deceleration snapping

extension SnapShortcutRailView: UIScrollViewDelegate {
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        targetContentOffset.pointee.y = Self.snappedTarget(
            proposed: targetContentOffset.pointee.y,
            restOffset: -contentInset.top,
            step: Self.step,
            maxOffset: contentSize.height - bounds.height
        )
    }
}
