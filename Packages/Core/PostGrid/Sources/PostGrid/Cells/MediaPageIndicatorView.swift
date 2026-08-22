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

    private let dots = UIStackView()
    private let label = UILabel()
    private var pageCount = 0

    public init() {
        dots.axis = .horizontal
        dots.alignment = .center
        dots.spacing = Self.dotSpacing
        label.font = PostMetaPillView.font
        label.textColor = PostMetaPillView.foreground
        label.adjustsFontForContentSizeCategory = true
        super.init(contents: [dots, label], spacing: 0)
        // The one chip that IS a control. `PostMetaPillView` turns interaction
        // off because a counter that swallowed touches would put a dead corner
        // on the preview; this one has something to do with them.
        isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTouch))
        addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTouch))
        addGestureRecognizer(pan)
    }

    /// A drag across the dots scrubs the pages, and the chip has to win that
    /// drag from the tab pager the way the carousel does.
    ///
    /// It cannot win it the same way: the pager yields to horizontally
    /// SCROLLABLE content under the touch, and this is a chip with a pan
    /// recognizer, not a scroll view. Declaring the intent is what closes the
    /// gap — see `HorizontalDragOwning`.
    ///
    /// A tap and a pan on one view, both to the same action: a dot tap is a
    /// zero-length scrub, so treating them as one thing means there is a single
    /// place that turns an x into a page.
    @objc private func handleTouch(_ recognizer: UIGestureRecognizer) {
        guard pageCount >= 2 else { return }
        onPageRequested?(
            Self.page(at: recognizer.location(in: self).x, width: bounds.width, count: pageCount)
        )
    }

    /// Which page a touch at `x` is asking for.
    ///
    /// Truncation, not rounding: the dots divide the strip into `count` equal
    /// BANDS and the viewer is pointing at a band, not at a boundary between
    /// two. Rounding makes the first and last bands half-width, so the ends —
    /// the two pages people reach for most — are the hardest to hit.
    ///
    /// The chip's own padding is removed first, so the bands span the dots
    /// rather than the capsule.
    static func page(at x: CGFloat, width: CGFloat, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let inset = insets.leading
        let usable = max(width - inset * 2, 1)
        let fraction = min(max((x - inset) / usable, 0), 1)
        return min(Int(fraction * CGFloat(count)), count - 1)
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

        let usesDots = count <= Self.dotLimit
        dots.isHidden = !usesDots
        label.isHidden = usesDots

        if usesDots {
            if dots.arrangedSubviews.count != count {
                dots.arrangedSubviews.forEach {
                    dots.removeArrangedSubview($0)
                    $0.removeFromSuperview()
                }
                for _ in 0..<count { dots.addArrangedSubview(makeDot()) }
            }
        }
        setCurrent(current)
    }

    /// Moves the mark without rebuilding, because this is called on every
    /// scroll callback of a carousel the viewer is dragging.
    public func setCurrent(_ current: Int) {
        guard pageCount >= 2 else { return }
        let page = min(max(current, 0), pageCount - 1)
        if pageCount <= Self.dotLimit {
            for (index, dot) in dots.arrangedSubviews.enumerated() {
                // Opacity, not colour: the chip's foreground is `.label`, which
                // already resolves against the interface style, and a second
                // colour here would be a second thing to keep in step with it.
                dot.alpha = index == page ? 1 : 0.35
            }
        } else {
            label.text = "\(page + 1) / \(pageCount)"
        }
    }

    private func makeDot() -> UIView {
        let dot = UIView()
        dot.backgroundColor = PostMetaPillView.foreground
        dot.layer.cornerRadius = Self.dotDiameter / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: Self.dotDiameter),
            dot.heightAnchor.constraint(equalToConstant: Self.dotDiameter)
        ])
        return dot
    }
}
