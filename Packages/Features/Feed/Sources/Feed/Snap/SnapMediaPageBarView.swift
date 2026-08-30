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
/// ## A window, past ten pictures
///
/// Ten segments is the most the strip draws. Beyond that it stops being a
/// diagram and becomes a texture — at twenty, a segment is thinner than the gap
/// beside it — so a window of ten slides through the run instead, with the mark
/// walking inside it and the run tapering away at whichever end it continues
/// past. That is the card indicator's own system (`PageWindow`), told
/// continuously here because this strip has a continuous position to tell it
/// with: a page leaving narrows and fades out while the one arriving grows in.
///
/// ## Frames, not a stack
///
/// How wide a segment is depends on the width and the count, both of which
/// change under this view; `UIStackView` would have to add and remove arranged
/// subviews inside a layout pass to answer that, which is the fight
/// `PageDotsView` and `MediaCarouselView` both avoid the same way.
///
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

    /// How many segments the strip draws at once, however many pictures there
    /// are.
    ///
    /// ⚠️ Past this the strip stops being a diagram and becomes a texture: at
    /// twenty, a segment is narrower than the gap beside it and the mark's
    /// 2.6× is a few points of nothing. Ten is where a run still reads as
    /// countable — and beyond it the WINDOW carries the rest, exactly as the
    /// card's chip does with five dots.
    static let maximumVisibleSegments = 10

    /// How many slots the run tapers over at an end it continues past.
    ///
    /// ⚠️ TWO, not one, and the card's note says why: the outermost segment
    /// shrinking says "there is more past here"; the one beside it, part-way
    /// down, says how the row is GOING. A single step from full size to nothing
    /// reads as a run that was cut; a slope reads as a run that continues.
    static let taperSlots: CGFloat = 2

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
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// The carousel moved, in fractional pages.
    ///
    /// Applied IMMEDIATELY and with NOTHING ELSE: this is the transposition,
    /// and a strip that eased its way toward the finger would lag the pictures
    /// it describes.
    ///
    /// ⚠️ AND NOTHING ELSE HAPPENS HERE — no accent, no easing, no second
    /// motion of any kind.
    ///
    /// A bounce lived here for two versions: first at the crossing, where it
    /// stretched a segment while the widths were still reflowing under the
    /// finger, and then at the settle, where it was at least alone. Both were
    /// removed. The strip already MOVES — its widths and its ink are a function
    /// of the scroll — and an accent laid over a thing that is already moving
    /// is a second motion on one object however well timed it is. What reads as
    /// alive here is the reflow itself.
    func setPosition(_ newPosition: CGFloat) {
        guard pageCount >= 2 else { return }
        position = min(max(newPosition, 0), CGFloat(pageCount - 1))
        layoutSegments()
    }

    /// A page arrived as a NUMBER rather than as a position — a post reopened
    /// on page three, a page set from outside.
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
        layoutSegments()
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutSegments()
    }

    /// Every segment's geometry and ink, from `position` and the window alone.
    ///
    /// Two curves, multiplied.
    ///
    /// The MARK is a tent: a segment is fully grown at its own page, resting a
    /// page away, linear in between — so two neighbours share the growth
    /// exactly while the viewer is between them.
    ///
    /// PRESENCE is how much of the strip a page is entitled to at all: 1 inside
    /// the window, tapering to nothing across the last two slots of an end the
    /// run continues past, 0 beyond. A page leaving therefore narrows and fades
    /// out while the one arriving grows in — the same information the card's
    /// dots give with a shrunken edge dot, told continuously because this strip
    /// has a continuous position to tell it with.
    ///
    /// The widths are shares of what is left after the gaps, so the run spans
    /// the column exactly at every position — including mid-slide, where the
    /// gaps of a half-arrived segment are themselves half-width.
    private func layoutSegments() {
        guard !segments.isEmpty, bounds.width > 0 else { return }
        let visible = visibleSlots
        updateWindowOrigin(visible: visible)
        let rooms = segments.indices.map { room(forPage: $0, visible: visible) }
        let weights = segments.indices.map {
            rooms[$0] * (1 + (Self.activeWidthFactor - 1) * proximity(toPage: $0))
        }
        let total = max(weights.reduce(0, +), 0.0001)
        // A gap belongs to a seam, and a seam is only as present as the thinner
        // of the two segments it separates.
        let gaps = segments.indices.dropLast().map { Self.gap * min(rooms[$0], rooms[$0 + 1]) }
        let available = max(bounds.width - gaps.reduce(0, +), 1)
        var x: CGFloat = 0
        for (index, segment) in segments.enumerated() {
            let width = available * weights[index] / total
            // ⚠️ bounds + centre rather than frame. They are the same thing
            // while nothing is transformed, and they stay right if anything
            // ever is: assigning a frame to a transformed view re-derives its
            // bounds and cancels the transform silently — the trap
            // `SnapFeedCell.pageStage` documents one view up.
            segment.bounds = CGRect(x: 0, y: 0, width: max(width, 0), height: bounds.height)
            segment.center = CGPoint(x: x + width / 2, y: bounds.height / 2)
            segment.layer.cornerRadius = min(bounds.height, max(width, 0)) / 2
            segment.alpha = rooms[index]
                * (Self.restingAlpha + (1 - Self.restingAlpha) * proximity(toPage: index))
            x += width + (index < gaps.count ? gaps[index] : 0)
        }
        // ⚠️ THE SCRUB TRACKS THE STRIP IT IS DRAWN ON. One page per average
        // slot, so the mark keeps pace with the thumb — the same rule as the
        // card's chip, at this strip's own scale. The AVERAGE, not the active
        // segment's own width, or the gesture's scale would change as it
        // travelled. Off the WINDOW, not the count: with a long run the thumb
        // still walks one slot per page, and the pages beyond simply arrive.
        scrubber.pointsPerPage = (bounds.width + Self.gap) / CGFloat(visible)
    }

    /// 1 on the page itself, 0 a page away, linear between — the tent above.
    private func proximity(toPage index: Int) -> CGFloat {
        max(0, 1 - abs(CGFloat(index) - position))
    }

    /// How much strip a page is entitled to: presence, except that the MARK is
    /// never tapered.
    ///
    /// ⚠️ The card's rule, and it exists because the two signals collide by
    /// construction: the taper says "the run continues past here" and the mark
    /// says "you are here", and the window deliberately parks the mark one slot
    /// in from the end it is heading for — which is exactly the slot the taper
    /// reaches. Shrinking the mark to say what its neighbours already say costs
    /// the one thing the strip is for.
    private func room(forPage index: Int, visible: Int) -> CGFloat {
        max(presence(ofPage: index, visible: visible), proximity(toPage: index))
    }

    /// 1 inside the window, tapering to 0 across `taperSlots` at an end the run
    /// continues past, 0 beyond it. Always 1 when the whole run fits.
    private func presence(ofPage index: Int, visible: Int) -> CGFloat {
        guard segments.count > visible else { return 1 }
        let slot = CGFloat(index) - windowOrigin
        let continuesBefore = windowOrigin > 0.0001
        let continuesAfter = windowOrigin + CGFloat(visible) < CGFloat(segments.count) - 0.0001
        // A run that genuinely ends here does not taper: there is nothing more
        // to promise. Half a slot of overhang either side so the outermost
        // segment is fully out before it is gone.
        let leading = continuesBefore
            ? (slot + 0.5) / Self.taperSlots : .greatestFiniteMagnitude
        let trailing = continuesAfter
            ? (CGFloat(visible) - 0.5 - slot) / Self.taperSlots : .greatestFiniteMagnitude
        return min(max(min(leading, trailing), 0), 1)
    }

    /// How many segments the strip draws at once.
    private var visibleSlots: Int { min(segments.count, Self.maximumVisibleSegments) }

    /// The window's leading slot, kept between passes: the mark walks inside
    /// the window and the window follows only when it has to. Fractional, so a
    /// window that has to follow slides with the finger instead of jumping a
    /// whole slot at the crossing.
    private var windowOrigin: CGFloat = 0

    private func updateWindowOrigin(visible: Int) {
        windowOrigin = PageWindow.start(
            current: position, visible: visible, count: segments.count, from: windowOrigin
        )
    }

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
    /// Read from bounds + centre rather than `frame`, which is also how the
    /// layout assigns them.
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

    /// Whether anything about a segment is animating.
    ///
    /// ⚠️ Kept after the accent was removed, because the claim it checks is now
    /// an ABSENCE — the strip is a function of the scroll and nothing about it
    /// animates on its own. An absence with no test is an absence that comes
    /// back.
    func debugSegmentIsAnimating(_ index: Int) -> Bool {
        guard segments.indices.contains(index) else { return false }
        return (segments[index].layer.animationKeys() ?? []).isEmpty == false
    }

    /// Drives the scrub without a finger; the simulator injects none.
    func debugScrub(_ state: UIGestureRecognizer.State, atX x: CGFloat) {
        handleScrub(state, atX: x)
    }
    #endif
}
