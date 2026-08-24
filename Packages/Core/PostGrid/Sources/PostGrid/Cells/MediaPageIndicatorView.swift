import DesignSystem
import UIKit

/// Which page of a collection the preview is showing, as the middle chip of the
/// row that already carries the counters and the age.
///
/// ## Two renderings, one view
///
/// **Dots** up to `dotLimit`, because dots are the carousel's universal signal
/// and read without being counted. **`3 / 14`** beyond it, because a row of
/// fourteen dots is a texture rather than a count — it stops answering "how far
/// in am I" at exactly the point the question starts mattering. The wire caps
/// nothing, so both cases are real.
///
/// ## Why it is a chip at all
///
/// It sits on a photograph, between two chips that already solved that problem.
/// Bare dots over media need a shadow or a scrim to survive a bright frame, and
/// the row would then contain two things that answer the question differently.
/// Same ground, same rule.
public final class MediaPageIndicatorView: PostMetaPillView, HorizontalDragOwning {
    /// Above this many pages, dots become a count. Eight is where a glanceable
    /// row stops being glanceable — the point at which the eye starts counting
    /// instead of seeing.
    public static let dotLimit = 8

    public static let dotDiameter: CGFloat = 6
    public static let dotSpacing: CGFloat = 5

    /// The viewer asked for a page, by tapping a dot or dragging across them.
    /// The HOST moves the carousel — an indicator that scrolled something for
    /// itself would be a second thing deciding where the pages are.
    public var onPageRequested: ((Int) -> Void)?

    /// The scrub, exposed so a host can make its OWN pan yield to it.
    ///
    /// ⚠️ A LONG PRESS OF ZERO DURATION, NOT A PAN — and that is the whole
    /// reason dragging the chip did nothing while tapping it worked.
    ///
    /// A pan must see MOVEMENT before it begins, and every scroll view above
    /// this chip is watching for exactly the same movement. The feed's
    /// collection view is an ancestor; it claimed the drag every time, so the
    /// pan here never got past `.possible` and the chip only ever responded to
    /// taps.
    ///
    /// A long press with no minimum duration begins on TOUCH-DOWN, before any
    /// scroll view has anything to go on, and then reports `.changed` for every
    /// movement — which is a scrubber exactly. `allowableMovement` is lifted
    /// because the default cancels a long press that travels, and travelling is
    /// the point.
    public let scrubGesture: UILongPressGestureRecognizer = {
        let scrub = UILongPressGestureRecognizer()
        scrub.minimumPressDuration = 0
        scrub.allowableMovement = .greatestFiniteMagnitude
        return scrub
    }()

    private let dots = PageDotsView()
    private let label = UILabel()
    private var pageCount = 0
    private var currentPage = 0

    public init() {
        label.font = PostMetaPillView.font
        label.textColor = PostMetaPillView.foreground
        label.adjustsFontForContentSizeCategory = true
        super.init(contents: [dots, label], spacing: 0)
        // The one chip that IS a control. `PostMetaPillView` turns interaction
        // off because a counter that swallowed touches would put a dead corner
        // on the preview; this one has something to do with them.
        isUserInteractionEnabled = true
        // No separate tap: a zero-duration long press already fires `.began` on
        // touch-down and `.ended` on lift, which IS a tap — and a second
        // recognizer competing for the same touch is how the drag was lost in
        // the first place.
        scrubGesture.addTarget(self, action: #selector(handleTouch))
        addGestureRecognizer(scrubGesture)
        // ⚠️ NOTHING ELSE MAY CLAIM THIS TOUCH.
        //
        // The chip sits inside a carousel that pans and, on the post screen,
        // under a dismissal that pans too — and a scrub is a horizontal drag,
        // which is exactly what both are looking for. Whoever won the race got
        // it, so scrubbing sometimes paged the carousel and sometimes dismissed
        // the post.
        //
        // Two halves here: `cancelsTouchesInView` keeps the touch from reaching
        // the views underneath, and `isExclusiveTouch` keeps a second finger
        // from starting something else mid-scrub. The third cannot live here —
        // a recognizer on an ANCESTOR is blocked by neither, so hosts must make
        // theirs stand down. See `scrubGesture`.
        scrubGesture.cancelsTouchesInView = true
        isExclusiveTouch = true
        // ⚠️ This chip YIELDS horizontal space; the counters and the date do not.
        //
        // It is the only one of the four whose content can be shown partially
        // and still mean something — a window of dots still says "there are
        // more, you are here" — while half a count or half a date says nothing.
        // So it compresses first, down to the floor `PageDotsView` sets.
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// - Parameters:
    ///   - count: how many pages the post has. One or zero hides the whole
    ///     chip — an indicator for a single page is furniture answering a
    ///     question nobody asked, and the chip row is already the busiest part
    ///     of the card.
    ///   - current: the page showing, clamped.
    public func configure(count: Int, current: Int) {
        pageCount = count
        isHidden = count < 2
        guard count >= 2 else { return }

        applyPresentation()
        setCurrent(current)
    }

    /// Dots or a count, decided in ONE place.
    ///
    /// ⚠️ Expanding overrides the limit on purpose. Above `dotLimit` a resting
    /// chip shows "3 / 12", because a dozen dots squeezed into a corner is a
    /// smear that says less than the number does. But the moment a finger is on
    /// it the chip is not a label any more, it is the thing being dragged — and
    /// what it must show then is WHERE the pages are, which only dots can say.
    private func applyPresentation() {
        let usesDots = isExpanded || pageCount <= Self.dotLimit
        dots.isHidden = !usesDots
        label.isHidden = usesDots
        if usesDots { dots.configure(count: pageCount) }
    }

    /// Whether the chip is showing itself in full for a scrub.
    public private(set) var isExpanded = false

    public func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded, pageCount >= 2 else { return }
        isExpanded = expanded
        applyPresentation()
        setCurrent(currentPage)
        invalidateIntrinsicContentSize()
    }

    /// What the chip needs to show every dot — the width a host must find for
    /// it, or decide it cannot.
    public var expandedContentWidth: CGFloat {
        PageDotsView.width(forDots: pageCount) + Self.insets.leading + Self.insets.trailing
    }

    /// Moves the mark without rebuilding, because this is called on every
    /// scroll callback of a carousel the viewer is dragging.
    public func setCurrent(_ current: Int) {
        guard pageCount >= 2 else { return }
        let page = min(max(current, 0), pageCount - 1)
        currentPage = page
        if isExpanded || pageCount <= Self.dotLimit {
            dots.setCurrent(page)
        } else {
            label.text = "\(page + 1) / \(pageCount)"
        }
    }

    /// The viewer began or ended scrubbing.
    ///
    /// Reported out, like the page request, because what "expanded" costs is a
    /// LAYOUT decision — which neighbours must yield, and whether any need to at
    /// all — and only the row that owns those neighbours can make it.
    public var onScrubbingChanged: ((Bool) -> Void)?

    /// Whether a finger is on the chip right now.
    public private(set) var isScrubbing = false {
        didSet {
            guard isScrubbing != oldValue else { return }
            onScrubbingChanged?(isScrubbing)
        }
    }

    @objc private func handleTouch(_ recognizer: UIGestureRecognizer) {
        guard pageCount >= 2 else { return }
        switch recognizer.state {
        case .began, .changed:
            isScrubbing = true
        case .ended, .cancelled, .failed:
            isScrubbing = false
        default:
            break
        }
        onPageRequested?(
            Self.page(at: recognizer.location(in: self).x, width: bounds.width, count: pageCount)
        )
    }

    /// Which page a touch at `x` is asking for.
    ///
    /// ⚠️ Across the WHOLE run of pages, even when only a window of dots is
    /// drawn. The chip is a scrubber, not a row of discrete targets: with a
    /// windowed indicator the visible dots are not the pages, so mapping a touch
    /// onto them would make the far right mean "the last dot I can see" rather
    /// than "the end" — and which page that is would change as the window moved.
    /// One rule at every width, and every page reachable at every width.
    ///
    /// Truncation, not rounding: the strip divides into `count` equal BANDS and
    /// the viewer is pointing at a band. Rounding makes the first and last bands
    /// half-width, so the two pages people reach for most become the hardest to
    /// hit.
    static func page(at x: CGFloat, width: CGFloat, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let inset = insets.leading
        let usable = max(width - inset * 2, 1)
        let fraction = min(max((x - inset) / usable, 0), 1)
        return min(Int(fraction * CGFloat(count)), count - 1)
    }

    /// The floor this chip may be compressed to: two dots plus its own padding.
    public var minimumChipWidth: CGFloat {
        dots.minimumWidth + Self.insets.leading + Self.insets.trailing
    }
}

/// The dots themselves, laid out by hand so the chip can be narrower than its
/// content.
///
/// ⚠️ A WINDOW, not a clipped row. When the counters and the date take the
/// space, this shows as many dots as fit — centred on the current page — rather
/// than the first N. Clipping would hide exactly the dot the viewer is looking
/// for the moment there are more pages than room, which is when an indicator
/// starts earning its place.
///
/// Frames rather than a stack, for the reason the carousel uses frames: how many
/// dots are visible is a function of the WIDTH, and a stack's arranged subviews
/// cannot be added and removed inside a layout pass without fighting it.
final class PageDotsView: UIView {
    /// The floor: two dots. One dot says nothing a single page would not, and
    /// the chip has to keep saying "there is more than one" at every width.
    static let minimumVisibleDots = 2

    private var count = 0
    private var current = 0
    private var dots: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(count: Int) {
        guard count != self.count else { return }
        self.count = count
        dots.forEach { $0.removeFromSuperview() }
        dots = (0..<count).map { _ in
            let dot = UIView()
            dot.backgroundColor = PostMetaPillView.foreground
            dot.layer.cornerRadius = MediaPageIndicatorView.dotDiameter / 2
            addSubview(dot)
            return dot
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func setCurrent(_ page: Int) {
        current = page
        // Opacity, not colour: the chip's foreground is `.label`, which already
        // resolves against the interface style, and a second colour here would
        // be a second thing to keep in step with it.
        for (index, dot) in dots.enumerated() { dot.alpha = index == page ? 1 : 0.35 }
        setNeedsLayout()
    }

    /// What the chip asks for when nothing is competing: every dot.
    override var intrinsicContentSize: CGSize {
        CGSize(width: Self.width(forDots: count), height: MediaPageIndicatorView.dotDiameter)
    }

    /// The floor the chip may be compressed to.
    var minimumWidth: CGFloat { Self.width(forDots: Self.minimumVisibleDots) }

    static func width(forDots visible: Int) -> CGFloat {
        guard visible > 0 else { return 0 }
        let diameter = MediaPageIndicatorView.dotDiameter
        let spacing = MediaPageIndicatorView.dotSpacing
        return CGFloat(visible) * diameter + CGFloat(visible - 1) * spacing
    }

    /// How many dots fit in `width`, never fewer than the floor and never more
    /// than there are pages.
    static func visibleDots(in width: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let diameter = MediaPageIndicatorView.dotDiameter
        let spacing = MediaPageIndicatorView.dotSpacing
        let fitted = Int(floor((width + spacing) / (diameter + spacing)))
        return min(count, max(fitted, minimumVisibleDots))
    }

    /// The first dot of the window, chosen so the current page sits in the
    /// middle of it and the window never runs off either end.
    static func windowStart(current: Int, visible: Int, count: Int) -> Int {
        guard count > visible else { return 0 }
        let half = visible / 2
        return min(max(current - half, 0), count - visible)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !dots.isEmpty else { return }
        let visible = Self.visibleDots(in: bounds.width, count: count)
        let start = Self.windowStart(current: current, visible: visible, count: count)
        let diameter = MediaPageIndicatorView.dotDiameter
        let spacing = MediaPageIndicatorView.dotSpacing
        // Centred in whatever width the row left: a window narrower than the
        // chip would otherwise sit against one edge and read as misaligned.
        let used = Self.width(forDots: visible)
        let originX = ((bounds.width - used) / 2).rounded()
        let y = ((bounds.height - diameter) / 2).rounded()
        for (index, dot) in dots.enumerated() {
            let offset = index - start
            guard offset >= 0, offset < visible else {
                dot.isHidden = true
                continue
            }
            dot.isHidden = false
            dot.frame = CGRect(
                x: originX + CGFloat(offset) * (diameter + spacing),
                y: y, width: diameter, height: diameter
            )
        }
    }
}
