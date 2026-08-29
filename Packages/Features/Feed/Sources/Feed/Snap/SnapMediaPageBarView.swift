import DesignSystem
import PostGrid
import UIKit

/// Which picture of a collection the post screen is showing: **one segment per
/// page, laid across the whole width of the column**, and the one you are on is
/// the wide one.
///
/// ## Why a bar and not the card's dots
///
/// The card's chip is furniture in a row of counters, sized to what it can
/// spare — five dots at most, a window sliding through the rest. This screen
/// has the whole width and one thing to say with it, so the strip says it the
/// way a strip can: every page gets a segment, and a segment's LENGTH is its
/// share of the width. Two pictures make two long pills; twelve make twelve
/// short ones, and the difference is legible before it is counted.
///
/// ## The strip is a function of the scroll
///
/// ⚠️ Its whole state is ONE number: where the carousel is, in fractional
/// pages. Width and ink are read off that number, so the strip reflows under
/// the finger for the entire gesture instead of waiting to be told a page has
/// changed — the crossing is a consequence of the drag, not the moment the
/// drawing may begin. Halfway between two pictures, both segments are half
/// grown and half lit.
///
/// The total width is invariant under that interpolation (the weights always
/// sum to the same number), so the run stays edge to edge while its insides
/// move. Anything else would be a strip that breathes at its ends, which reads
/// as a layout bug rather than as motion.
///
/// ## Frames, not a stack — and bounds/centre, not frames
///
/// How wide a segment is depends on the width and the count, both of which
/// change under this view; `UIStackView` would have to add and remove arranged
/// subviews inside a layout pass to answer that, which is the fight
/// `PageDotsView` and `MediaCarouselView` both avoid the same way.
///
/// ⚠️ And the geometry is assigned as `bounds` + `center`, never `frame`,
/// because the handover pop is a TRANSFORM: assigning a frame to a transformed
/// view re-derives its bounds from it and cancels the transform silently. The
/// same trap `SnapFeedCell.pageStage` documents, one view down.
final class SnapMediaPageBarView: UIView {
    /// The strip's thickness — the card's dot diameter, so this reads as the
    /// same ink stretched rather than as a different control.
    static let thickness: CGFloat = MediaPageIndicatorView.dotDiameter

    /// The gap between two segments. Small enough that the run reads as one
    /// strip, wide enough that the divisions are not a moiré at twelve pages.
    static let gap: CGFloat = Spacing.xs

    /// How much wider the page you are on is than the rest.
    ///
    /// ⚠️ Wide enough that the answer survives a glance at twelve pages: at
    /// 2.6 the active pill is unmistakably the long one whatever the count,
    /// where 1.5 read as "the segments are uneven" rather than as a mark.
    static let activeWidthFactor: CGFloat = 2.6

    /// The ink the pages you are not on are drawn in — the card's own ratio.
    static let restingAlpha: CGFloat = 0.35

    /// The viewer asked for a page by dragging along the strip. The HOST moves
    /// the carousel — an indicator that scrolled something for itself would be
    /// a second thing deciding where the pages are.
    var onPageRequested: ((Int) -> Void)?

    /// The scrub, exposed so a host can make its OWN pan yield to it.
    ///
    /// ⚠️ A long press of zero duration, not a pan, for the reason the card's
    /// chip states at length: a pan must see movement before it begins, and
    /// every scroll view above this strip is watching for the same movement, so
    /// the ancestor claims it every time. A long press begins on touch-down,
    /// before anything else has anything to go on.
    let scrubGesture: UILongPressGestureRecognizer = {
        let scrub = UILongPressGestureRecognizer()
        scrub.minimumPressDuration = 0
        scrub.allowableMovement = .greatestFiniteMagnitude
        scrub.cancelsTouchesInView = true
        return scrub
    }()

    private var segments: [UIView] = []
    private var pageCount = 0
    /// Where the carousel is, in fractional pages — the strip's entire state.
    private var position: CGFloat = 0
    /// The shared arithmetic; its scale is set from the layout, below.
    private var scrubber = PageScrubber(pointsPerPage: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        isExclusiveTouch = true
        scrubGesture.addTarget(self, action: #selector(handleScrubGesture))
        addGestureRecognizer(scrubGesture)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.thickness)
    }

    /// One segment per page. Hidden entirely below two — a single picture has
    /// no position to report, and one full-width pill would claim it did.
    func configure(count: Int, current: Int) {
        pageCount = count
        isHidden = count < 2
        guard count >= 2 else { return }
        if segments.count != count {
            segments.forEach { $0.removeFromSuperview() }
            segments = (0..<count).map { _ in
                let view = UIView()
                view.backgroundColor = .white
                view.layer.cornerRadius = Self.thickness / 2
                view.isUserInteractionEnabled = false
                addSubview(view)
                return view
            }
        }
        position = CGFloat(min(max(current, 0), count - 1))
        settledPage = Int(position)
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// The carousel moved, in fractional pages.
    ///
    /// Applied IMMEDIATELY and with NOTHING ELSE: this is the transposition,
    /// and a strip that eased its way toward the finger would lag the pictures
    /// it describes.
    ///
    /// ⚠️ AND NO ACCENT HERE. The bounce used to fire at the crossing, with the
    /// finger still down and the widths still reflowing — a stretch on top of a
    /// reflow, twice per page on a long drag, which reads as the strip stumbling
    /// rather than as motion. Reported as "pas très fluide", and the diagnosis
    /// was right: two motions on one object, only one of which the viewer was
    /// asking for. The accent belongs to the SETTLE — see `settle(at:)`.
    func setPosition(_ newPosition: CGFloat) {
        guard pageCount >= 2 else { return }
        position = min(max(newPosition, 0), CGFloat(pageCount - 1))
        layoutSegments()
    }

    /// The scroll came to rest on `page` — the snap at the end of a drag.
    ///
    /// This is the strip's one accent, and the only place it is allowed to
    /// happen: at rest there is nothing else moving, so a bounce here is
    /// punctuation rather than interference.
    ///
    /// ⚠️ ONLY WHEN THE PAGE ACTUALLY CHANGED. A drag that snaps back to where
    /// it started is a settle too, and bouncing there would accent the absence
    /// of an event.
    func settle(at page: Int) {
        guard pageCount >= 2 else { return }
        let landed = min(max(page, 0), pageCount - 1)
        position = CGFloat(landed)
        layoutSegments()
        defer { settledPage = landed }
        guard landed != settledPage else { return }
        pop(landed)
    }

    /// The page the last settle landed on, so a snap-back is not an arrival.
    private var settledPage = 0

    /// A page arrived as a NUMBER rather than as a position — a post reopened
    /// on page three, a page set from outside. There is a real distance to
    /// travel here, so this one springs.
    ///
    /// ⚠️ IT MUST NOT ACT ON A PAGE THE STRIP IS ALREADY ON, and "already on"
    /// means the rounded position, not an exact match. The carousel reports
    /// both signals: a fraction on every scroll callback and a page number at
    /// the crossing. Halfway through a drag the fraction is 0.52 and the page
    /// number is 1 — both true, and a strip that sprang to 1.0 on the second
    /// would jump ahead of the finger and be dragged back by the next fraction.
    /// A page it already agrees with is nothing to do.
    func setCurrent(_ page: Int) {
        guard pageCount >= 2 else { return }
        let target = CGFloat(min(max(page, 0), pageCount - 1))
        guard Int(position.rounded()) != Int(target) else { return }
        position = target
        settledPage = Int(target)
        UIView.animate(
            withDuration: Self.springDuration, delay: 0,
            usingSpringWithDamping: Self.springDamping, initialSpringVelocity: 0.6,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.layoutSegments()
        }
    }

    /// ⚠️ A spring the eye reads as WEIGHT, not as a wobble: under-damped
    /// enough to overshoot once and settle, over a duration short enough that
    /// the strip is never still behind a finger that has moved on.
    private static let springDamping: CGFloat = 0.62
    private static let springDuration: TimeInterval = 0.42

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutSegments()
    }

    /// Every segment's geometry and ink, from `position` alone.
    ///
    /// The weight curve is a tent: a segment is fully grown at its own page,
    /// resting a page away, and linear in between — so two neighbours share the
    /// growth exactly while the viewer is between them, and the weights sum to
    /// the same total at every position. That invariance is what keeps the run
    /// edge to edge mid-drag.
    private func layoutSegments() {
        guard !segments.isEmpty, bounds.width > 0 else { return }
        let count = CGFloat(segments.count)
        let available = max(bounds.width - Self.gap * (count - 1), 1)
        let weights = segments.indices.map { weight(forPage: $0) }
        let total = weights.reduce(0, +)
        var x: CGFloat = 0
        for (index, segment) in segments.enumerated() {
            let width = max(available * weights[index] / total, 1)
            // ⚠️ bounds + centre, never frame: the pop is a transform, and a
            // frame assignment would cancel it (see the type's note).
            segment.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            segment.center = CGPoint(x: x + width / 2, y: bounds.height / 2)
            segment.layer.cornerRadius = min(bounds.height, width) / 2
            segment.alpha = Self.restingAlpha
                + (1 - Self.restingAlpha) * proximity(toPage: index)
            x += width + Self.gap
        }
        // ⚠️ THE SCRUB TRACKS THE STRIP IT IS DRAWN ON. One page per average
        // segment stride, so the mark keeps pace with the thumb — the same rule
        // as the card's chip, at this strip's own scale. The AVERAGE, not the
        // active segment's own width, or the gesture's scale would change as it
        // travelled.
        scrubber.pointsPerPage = (bounds.width + Self.gap) / count
    }

    /// 1 on the page itself, 0 a page away, linear between — the tent above.
    private func proximity(toPage index: Int) -> CGFloat {
        max(0, 1 - abs(CGFloat(index) - position))
    }

    private func weight(forPage index: Int) -> CGFloat {
        1 + (Self.activeWidthFactor - 1) * proximity(toPage: index)
    }

    /// The arrival's bounce: the segment that has just taken the mark stretches
    /// along the strip and springs back.
    ///
    /// One caller, `settle(at:)`, and that is the whole of the rule — the strip
    /// moves with the scroll and accents only where the scroll stops.
    ///
    /// ⚠️ A TRANSFORM, not a width. The widths are already being driven by the
    /// scroll — animating them here would be two things writing one number, and
    /// the loser is whichever ran second. A transform is a separate channel: it
    /// rides on top of whatever the layout is doing, which is exactly what an
    /// accent should do.
    private func pop(_ index: Int) {
        guard segments.indices.contains(index) else { return }
        let segment = segments[index]
        segment.transform = CGAffineTransform(scaleX: Self.popScale, y: 1)
        UIView.animate(
            withDuration: Self.springDuration, delay: 0,
            usingSpringWithDamping: Self.springDamping, initialSpringVelocity: 0.9,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            segment.transform = .identity
        }
    }

    /// Along the strip only — a pill that grew in both directions would leave
    /// its own line, and the line is the thing being read.
    private static let popScale: CGFloat = 1.16

    // MARK: - Scrubbing

    @objc private func handleScrubGesture(_ recognizer: UIGestureRecognizer) {
        handleScrub(recognizer.state, atX: recognizer.location(in: self).x)
    }

    /// ⚠️ TOUCHING IT ASKS FOR NOTHING; ONLY DRAGGING DOES — the card's rule,
    /// and it matters more here: this strip is full-width, so an absolute read
    /// would send a twelve-page post to page six the moment a thumb landed
    /// anywhere near the middle of the screen.
    private func handleScrub(_ state: UIGestureRecognizer.State, atX x: CGFloat) {
        guard pageCount >= 2 else { return }
        switch state {
        case .began:
            scrubber.begin(atX: x, page: Int(position.rounded()))
        case .changed:
            if let page = scrubber.page(draggedTo: x, pageCount: pageCount) {
                onPageRequested?(page)
            }
        default:
            break
        }
    }

    /// ⚠️ A STRIP THIS THIN NEEDS A TALLER TARGET. Six points is a legible
    /// mark and an unhittable control, so the touch area is grown to the
    /// platform's minimum around it — outward only, which costs the layout
    /// nothing because the band it grows into is the breathing room between
    /// the caption and the bar.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let grown = bounds.insetBy(dx: 0, dy: -(Self.minimumTouchHeight - bounds.height) / 2)
        return grown.contains(point)
    }

    private static let minimumTouchHeight: CGFloat = 44

    #if DEBUG
    /// Where a segment is drawn, so a spec can state the claims that make this
    /// view different from the dots: the segments SHARE the width, and the one
    /// you are on takes the larger share.
    ///
    /// Read from bounds + centre rather than `frame`, so a pop in flight does
    /// not report as a wider segment.
    func debugSegmentFrame(_ index: Int) -> CGRect? {
        guard segments.indices.contains(index) else { return nil }
        let segment = segments[index]
        return CGRect(
            x: segment.center.x - segment.bounds.width / 2,
            y: segment.center.y - segment.bounds.height / 2,
            width: segment.bounds.width, height: segment.bounds.height
        )
    }

    /// How strongly a segment is drawn — the mark, read without a screenshot.
    func debugSegmentAlpha(_ index: Int) -> CGFloat? {
        segments.indices.contains(index) ? segments[index].alpha : nil
    }

    /// Whether a segment is mid-pop — the bounce, which is a transform and so
    /// invisible to every geometry above.
    func debugSegmentIsPopping(_ index: Int) -> Bool {
        guard segments.indices.contains(index) else { return false }
        return segments[index].layer.animation(forKey: "transform") != nil
    }

    /// Drives the scrub without a finger; the simulator injects none.
    func debugScrub(_ state: UIGestureRecognizer.State, atX x: CGFloat) {
        handleScrub(state, atX: x)
    }
    #endif
}
