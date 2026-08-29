import DesignSystem
import PostGrid
import UIKit

/// Which picture of a collection the post screen is showing: **one segment per
/// page, laid across the whole width of the column**.
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
/// It also stops the indicator being a small target floating over the
/// photograph. Down here it is a full-width control between the caption and the
/// bar — the place a viewer already looks for a position.
///
/// ## Frames, not a stack
///
/// How wide a segment is depends on the width and the count, both of which
/// change under this view (a rotation, a re-configure). `UIStackView` would
/// have to add and remove arranged subviews inside a layout pass to answer
/// that, which is the fight `PageDotsView` and `MediaCarouselView` both avoid
/// the same way.
final class SnapMediaPageBarView: UIView {
    /// The strip's thickness — the card's dot diameter, so this reads as the
    /// same ink stretched rather than as a different control.
    static let thickness: CGFloat = MediaPageIndicatorView.dotDiameter

    /// The gap between two segments. Small enough that the run reads as one
    /// strip, wide enough that the divisions are not a moiré at twelve pages.
    static let gap: CGFloat = Spacing.xs

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
    private var currentPage = 0
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
            setNeedsLayout()
        }
        setCurrent(current)
    }

    /// Moves the mark without rebuilding — this runs on every scroll callback
    /// of a carousel under a finger.
    func setCurrent(_ page: Int) {
        guard pageCount >= 2 else { return }
        currentPage = min(max(page, 0), pageCount - 1)
        for (index, segment) in segments.enumerated() {
            // The card's own ratio: the page you are on is the ink, the rest is
            // the same ink held back.
            segment.alpha = index == currentPage ? 1 : 0.35
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !segments.isEmpty, bounds.width > 0 else { return }
        let count = CGFloat(segments.count)
        let width = max((bounds.width - Self.gap * (count - 1)) / count, 1)
        let stride = width + Self.gap
        for (index, segment) in segments.enumerated() {
            segment.frame = CGRect(
                x: CGFloat(index) * stride, y: 0, width: width, height: bounds.height
            )
        }
        // ⚠️ THE SCRUB TRACKS THE STRIP IT IS DRAWN ON. A segment's stride is
        // how far the finger travels for one page here, so the mark keeps pace
        // with the thumb instead of running ahead of it — the same rule as the
        // chip's, at this strip's own scale.
        scrubber.pointsPerPage = stride
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
            scrubber.begin(atX: x, page: currentPage)
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
    /// Where a segment is drawn, so a spec can state the claim that makes this
    /// view different from the dots: the segments SHARE the width.
    func debugSegmentFrame(_ index: Int) -> CGRect? {
        segments.indices.contains(index) ? segments[index].frame : nil
    }

    /// How strongly a segment is drawn — the mark, read without a screenshot.
    func debugSegmentAlpha(_ index: Int) -> CGFloat? {
        segments.indices.contains(index) ? segments[index].alpha : nil
    }

    /// Drives the scrub without a finger; the simulator injects none.
    func debugScrub(_ state: UIGestureRecognizer.State, atX x: CGFloat) {
        handleScrub(state, atX: x)
    }
    #endif
}
