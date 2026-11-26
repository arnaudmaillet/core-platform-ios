import CoreModels
import DesignSystem
import UIKit

/// The person pill's second line, which may SCROLL (#2409): the full-screen
/// page's followed author shows the post's sound there (`♪ title · artist`),
/// and a sound longer than the line slides through it — to its end, a rest,
/// and back — instead of truncating.
///
/// The label is the pill's own handle label, hosted here: it keeps its style,
/// its shadow and its compression rules, and this view reports the label's
/// size, so the pill's width arithmetic is the label's. Not scrolling, the
/// label fills the line and truncates as before.
///
/// ⚠️ DECORATION, SO IT RESTS (#580): an endless animation recomposites the
/// whole frame, the toolbar's glass included. It stops while
/// `MotionPreference.stillsDecoration` holds (Reduce Motion, Low Power Mode,
/// the app at rest) and off a window, and the text then truncates.
final class PersonPillScrollingLine: UIView {
    let label: UILabel
    /// Whether a line longer than the room slides through it.
    var scrolls = false {
        didSet { if scrolls != oldValue { setNeedsLayout() } }
    }

    /// The slide's speed, and the rest at each end.
    static let pointsPerSecond: CGFloat = 30
    static let rest: CFTimeInterval = 1.5
    private static let animationKey = "personPill.scroll"

    /// The distance the running slide covers; nil while still.
    private(set) var scrollDistance: CGFloat?
    private let observers = NotificationTokens()

    init(label: UILabel) {
        self.label = label
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(label)
        // The label's own rules, so the stack weighs this line as it did the label.
        for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
            setContentHuggingPriority(label.contentHuggingPriority(for: axis), for: axis)
            setContentCompressionResistancePriority(label.contentCompressionResistancePriority(for: axis), for: axis)
        }
        observers.observe(.decorativeMotionDidChange) { [weak self] in self?.setNeedsLayout() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize { label.intrinsicContentSize }

    /// The label's text changed: its size is this line's.
    func textDidChange() {
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let natural = ceil(label.intrinsicContentSize.width)
        let overflow = natural - bounds.width
        guard scrolls, overflow > 0.5, window != nil, !MotionPreference.stillsDecoration else {
            stop()
            label.frame = bounds
            return
        }
        label.frame = CGRect(x: 0, y: 0, width: natural, height: bounds.height)
        guard scrollDistance != overflow else { return }
        start(over: overflow)
    }

    /// To the line's end, a rest, back to its start, a rest — again. The
    /// line scrolls its own bounds over the label, as a scroll view does: a
    /// scroll, not a translation of the label (a head-shake's keyframe is
    /// DesignSystem's alone, `SharedHelperGuardTests`).
    private func start(over distance: CGFloat) {
        stop()
        scrollDistance = distance
        let travel = CFTimeInterval(distance / Self.pointsPerSecond)
        let total = 2 * (Self.rest + travel)
        let slide = CAKeyframeAnimation(keyPath: "bounds.origin.x")
        slide.values = [0, 0, distance, distance, 0]
        slide.keyTimes = [0, Self.rest / total, (Self.rest + travel) / total, (2 * Self.rest + travel) / total, 1]
            .map { NSNumber(value: $0) }
        slide.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4)
        slide.duration = total
        slide.repeatCount = .infinity
        slide.isRemovedOnCompletion = false
        layer.add(slide, forKey: Self.animationKey)
    }

    private func stop() {
        guard scrollDistance != nil else { return }
        scrollDistance = nil
        layer.removeAnimation(forKey: Self.animationKey)
    }
}
