import UIKit

/// Pull the inbox down past a line and let go: search opens — the Mail and
/// Telegram gesture, in place of the pull-to-refresh the inbox's pages used to
/// wear.
///
/// **Why a pull, and why this replaces refresh.** The inbox is live: the list
/// reloads every time it appears and every time a page becomes active, so a
/// hand-pulled refresh was a second way to do something already done — while
/// search, the thing people actually reach for at the top of a list of
/// conversations, sat in the far corner of the bar. The pull now goes where the
/// thumb already is.
///
/// **One object for every page.** The inbox has three pages, each with its own
/// table; the container hands this object whichever one is in front
/// (`HorizontalPagerView.onActiveScrollViewChanged`), and it follows that one
/// table's offset. The indicator is the CONTAINER's view, not a page's, so it
/// stays put while pages change under it and is drawn once.
///
/// **The gesture is the scroll view's own.** Nothing here adds a recognizer
/// that could compete with the pager's horizontal pan or the stack's edge-swipe
/// pop: it watches `contentOffset` (KVO) for the pull and the table's own
/// `panGestureRecognizer` (an extra target, which claims nothing) for the
/// release. A horizontal page swipe never moves a table's vertical offset, so
/// it cannot arm this; the container additionally disables it while a page
/// change is in flight.
///
/// **The affordance.** A small search capsule is revealed in the gap the pull
/// opens under the bar, growing and fading in with the distance. Crossing the
/// line ARMS it — the capsule inverts, its label says "Release to search", and
/// a light haptic marks the moment — and letting go while armed opens search.
/// Pulling back above the line before letting go disarms it, silently: the
/// gesture can always be abandoned.
@MainActor
final class InboxPullToSearch: NSObject {
    /// How far past the resting position the list has to be pulled to arm.
    ///
    /// A little more than the capsule and its breathing room, so the capsule
    /// has fully arrived by the time it arms — arming a half-drawn control
    /// reads as a glitch — and a flick at the top of the list, which bounces
    /// a few dozen points, never gets there by accident.
    static let threshold: CGFloat = 84
    /// Once armed, how far back up the finger may drift before it disarms.
    /// Without the margin a finger resting ON the line toggles the state (and
    /// the haptic) with every tremor.
    static let disarmMargin: CGFloat = 10

    /// The capsule. Owned here, placed by the container.
    let indicator = PullToSearchIndicatorView()

    /// What a release past the line does — the container's `presentSearch`,
    /// the magnifier's own path.
    var onTrigger: (() -> Void)?

    /// Gated by the container: off while searching (the list is covered and
    /// the bar is a field already) and while a page change is in flight.
    var isEnabled = true {
        didSet { if !isEnabled { disarm() } }
    }

    private weak var scrollView: UIScrollView?
    private var offsetObservation: NSKeyValueObservation?
    private(set) var isArmed = false
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    #if DEBUG
    /// Stands in for `isTracking` while the QA hook drives the offset — a
    /// simulator cannot inject the pan, so the hook moves the list the way a
    /// finger would and says so here.
    var debugIsTracking = false
    #endif

    // MARK: - Attaching

    /// Follows `scrollView` from now on, dropping whichever was followed
    /// before. Idempotent for the same scroll view.
    func attach(to scrollView: UIScrollView) {
        guard scrollView !== self.scrollView else { return }
        detach()
        self.scrollView = scrollView
        // The pull needs something to pull on. The refresh control that used
        // to live on these tables forced a bounce on its own; without it a
        // list shorter than the screen would not move at all.
        scrollView.alwaysBounceVertical = true
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(panDidChange(_:)))
        offsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.offsetDidChange() }
        }
        offsetDidChange()
    }

    private func detach() {
        offsetObservation?.invalidate()
        offsetObservation = nil
        scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(panDidChange(_:)))
        scrollView = nil
        disarm()
        indicator.setPull(distance: 0, threshold: Self.threshold)
    }

    // MARK: - Tracking

    /// How far the list is pulled past its resting top, in points; zero when
    /// it is at or above it.
    ///
    /// Measured against `adjustedContentInset.top` — the list runs under the
    /// bar, so its resting offset is minus the bar's height, not zero.
    var pullDistance: CGFloat {
        guard let scrollView else { return 0 }
        return max(0, -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top))
    }

    private var isTracking: Bool {
        #if DEBUG
        if debugIsTracking { return true }
        #endif
        return scrollView?.isTracking ?? false
    }

    private func offsetDidChange() {
        let distance = pullDistance
        // The capsule follows the list in BOTH directions, finger down or
        // not, so it slides away with the bounce-back rather than blinking out.
        indicator.setPull(distance: isEnabled ? distance : 0, threshold: Self.threshold)
        // Arming follows the FINGER only: a list bouncing back through the
        // line after a release must not arm on its way past.
        guard isEnabled, isTracking else { return }
        if distance > 0 { haptic.prepare() }
        if !isArmed, distance >= Self.threshold {
            isArmed = true
            indicator.setArmed(true)
            haptic.impactOccurred()
        } else if isArmed, distance < Self.threshold - Self.disarmMargin {
            disarm()
        }
    }

    @objc private func panDidChange(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .ended:
            release()
        case .cancelled, .failed:
            // A cancelled pan is not a decision — an incoming call, a system
            // gesture. Nothing opens.
            disarm()
        default:
            break
        }
    }

    /// The finger lifted: open search if armed, and in every case stand down.
    func release() {
        let fire = isArmed && isEnabled
        disarm()
        if fire { onTrigger?() }
    }

    private func disarm() {
        guard isArmed else { return }
        isArmed = false
        indicator.setArmed(false)
    }

    #if DEBUG
    /// The list being followed, for the QA hook's readiness check.
    var debugScrollView: UIScrollView? { scrollView }

    /// Moves the followed list to a pull of `distance`, one frame at a time
    /// over `duration`, with the gesture marked as tracking — every frame goes
    /// through the real KVO path, so the capsule, the arming and the haptic
    /// are the production ones.
    func debugPull(to distance: CGFloat, duration: TimeInterval, completion: @escaping @MainActor () -> Void) {
        guard let scrollView else { return }
        debugIsTracking = true
        let resting = -scrollView.adjustedContentInset.top
        let start = CACurrentMediaTime()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            // The timer is invalidated OUT here: handing it into the
            // main-actor closure below is a send the compiler rightly refuses.
            let finished = MainActor.assumeIsolated { () -> Bool in
                guard let self, let scrollView = self.scrollView else { return true }
                let fraction = min((CACurrentMediaTime() - start) / duration, 1)
                // Ease-out, like a finger slowing against the rubber band.
                let eased = 1 - pow(1 - fraction, 2)
                scrollView.contentOffset.y = resting - distance * eased
                guard fraction >= 1 else { return false }
                completion()
                return true
            }
            if finished { timer.invalidate() }
        }
    }

    /// Lets go, through the same `release()` a lifted finger reaches, and
    /// springs the list back the way the rubber band would.
    func debugRelease() {
        debugIsTracking = false
        release()
        guard let scrollView else { return }
        let resting = -scrollView.adjustedContentInset.top
        // ⚠️ NOT `setContentOffset(_:animated: true)`. From an offset set by
        // hand past the top, it landed a whole pull-distance ABOVE the rest
        // position (measured: rest -116, pulled to -166, landed at -65) — the
        // list left scrolled under the bar. A plain animated assignment lands
        // where it is told.
        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            scrollView.contentOffset.y = resting
        }
    }
    #endif
}

/// The capsule a pull reveals: a magnifier and a word, like the top of a
/// search field arriving from under the bar.
///
/// It lives in the gap the pull opens: centred in it once the gap is taller
/// than the capsule, grown from 70% and faded in with the distance, and
/// INVERTED when armed — the one state change that has to be unmistakable,
/// because it is the difference between letting go doing something and
/// nothing.
final class PullToSearchIndicatorView: UIView {
    private let glyph = UIImageView(image: UIImage(systemName: "magnifyingglass"))
    private let label = UILabel()
    private let stack = UIStackView()

    static let height: CGFloat = 36

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // Not an accessibility element: the gesture has a button twin (the
        // magnifier in the bar), which is the path VoiceOver takes.
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        alpha = 0
        layer.cornerRadius = Self.height / 2
        layer.cornerCurve = .continuous

        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium)
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        stack.addArrangedSubview(glyph)
        stack.addArrangedSubview(label)
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14)
        ])
        applyArmed(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Places and fades the capsule for a pull of `distance`.
    ///
    /// The view is pinned just under the bar; this only TRANSFORMS it, so a
    /// per-frame offset change never costs a layout pass.
    func setPull(distance: CGFloat, threshold: CGFloat) {
        let progress = min(max(distance / threshold, 0), 1)
        // Invisible for the first few points — a list resting a hair past its
        // top (a bounce settling) should not flicker a control into view.
        alpha = min(max((distance - 12) / (threshold * 0.55), 0), 1)
        let scale = 0.7 + 0.3 * progress
        // Centred in the gap once the gap can hold it; pinned at the top until
        // then, so it emerges from under the bar rather than out of nowhere.
        let lift = max(0, (distance - Self.height) / 2)
        transform = CGAffineTransform(translationX: 0, y: lift).scaledBy(x: scale, y: scale)
    }

    func setArmed(_ armed: Bool) {
        UIView.animate(withDuration: 0.16, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.applyArmed(armed)
        }
    }

    private func applyArmed(_ armed: Bool) {
        // `.label` on `.systemBackground` when armed: the header's own ink
        // (every bar glyph is tinted `.label`), inverted — legible in light and
        // dark alike, and nothing like the resting fill.
        backgroundColor = armed ? .label : .secondarySystemFill
        let ink: UIColor = armed ? .systemBackground : .secondaryLabel
        glyph.tintColor = ink
        label.textColor = ink
        label.text = armed ? "Release to search" : "Pull to search"
    }

    #if DEBUG
    var debugLabelText: String? { label.text }
    #endif
}
