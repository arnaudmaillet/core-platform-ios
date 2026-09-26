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
/// opens under the bar, growing and fading in with the distance while a ring
/// around its magnifier fills toward the line. Crossing the line ARMS it — the
/// ink floods the capsule from the glyph, its words become "Release to
/// search", and a light haptic marks the moment — and letting go while armed
/// opens search. Pulling back above the line before letting go disarms it,
/// silently, the flood draining back: the gesture can always be abandoned.
/// The motion itself is `PullToSearchIndicatorView`'s.
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

    /// Moves the followed list from wherever it is to a pull of `distance`,
    /// one frame at a time over `duration`, with the gesture marked as
    /// tracking — every frame goes through the real KVO path, so the capsule,
    /// the meter, the arming and the haptic are the production ones. Starting
    /// from the CURRENT pull is what lets the hook chain moves (past the line,
    /// back above it, past it again) the way a hesitating finger would.
    func debugPull(to distance: CGFloat, duration: TimeInterval, completion: @escaping @MainActor () -> Void) {
        guard let scrollView else { return }
        debugIsTracking = true
        let resting = -scrollView.adjustedContentInset.top
        let from = pullDistance
        let start = CACurrentMediaTime()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            // The timer is invalidated OUT here: handing it into the
            // main-actor closure below is a send the compiler rightly refuses.
            let finished = MainActor.assumeIsolated { () -> Bool in
                guard let self, let scrollView = self.scrollView else { return true }
                let fraction = min((CACurrentMediaTime() - start) / duration, 1)
                // Ease-out, like a finger slowing against the rubber band.
                let eased = 1 - pow(1 - fraction, 2)
                scrollView.contentOffset.y = resting - (from + (distance - from) * eased)
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

/// The capsule a pull reveals: a magnifier in a ring and a line of text, like
/// the top of a search field arriving from under the bar.
///
/// **Two states, one continuous motion between them.** The capsule used to
/// SWAP: one frame "Pull to search" on a grey fill, the next "Release to
/// search" inverted. Now every step of the gesture is drawn:
///
/// - **Approaching the line** — the capsule grows from 70% and fades in with
///   the distance (as before), and the ring around the magnifier fills with
///   it, clockwise from the top: a meter of how much further to go, so the
///   line is something the thumb can SEE coming rather than a surprise.
/// - **Crossing it** — the ring is full, and the ink it was drawn in floods
///   out of the magnifier across the capsule (a circle growing from the glyph,
///   on a spring with a little bounce), while "Pull to search" fades and
///   "Release to search" fades in under the flood, the capsule widens to fit
///   the longer words and gives a small pop — the visual twin of the haptic.
///   Under the wavefront the glyph and text are drawn inverted, so the
///   inversion travels rather than blinks.
/// - **Backing off** — the flood drains back into the glyph (an accelerating
///   curve, no spring: a retreat should not wobble), the words swap
///   back, and the ring is there again, a little short of full, exactly where
///   the finger is.
///
/// ⚠️ **Crossfades animate CONTAINERS, never a label's own alpha.** Each label
/// sits in a plain view whose alpha fades: a label's partial view alpha is
/// drawn opaque when it ends up on a glass platter, and the text of a
/// crossfade must never depend on where the capsule is hosted.
///
/// **Reduce Motion** keeps the meaning and drops the movement: no growth on
/// arrival (the capsule only fades in), no flood, no pop, no spring — the
/// inverted capsule and its words crossfade in place.
///
/// The view itself never changes size: it is as wide as the ARMED capsule, so
/// the container's constraints never re-lay out mid-gesture (a layout pass
/// flushed inside an animation block is how whole screens "unfold"). The
/// capsule inside it is framed by hand and animates its own width.
final class PullToSearchIndicatorView: UIView {
    static let height: CGFloat = 36

    /// "Pull to search" / "Release to search" — the idiom every pull gesture
    /// on the platform speaks, kept on purpose: the verb says what the hand
    /// has to do next, the object says what it gets.
    static let pullTitle = "Pull to search"
    static let releaseTitle = "Release to search"

    /// The part of the pull that happens before the capsule starts to show:
    /// a list resting a hair past its top (a bounce settling) must not
    /// flicker a control into view, nor tick its meter.
    static let deadZone: CGFloat = 12

    /// Room inside the capsule. The ring already carries its own air around
    /// the glyph, so the leading side needs less than the trailing one.
    private static let leadingPadding: CGFloat = 7
    private static let trailingPadding: CGFloat = 14
    /// The ring around the magnifier — the progress meter.
    private static let ringDiameter: CGFloat = 24
    private static let ringWidth: CGFloat = 2
    private static let spacing: CGFloat = 6
    /// The flood's resting scale: a dot inside the glyph. Not zero — a
    /// singular transform cannot be animated out of.
    private static let collapsedBloom = CGAffineTransform(scaleX: 0.001, y: 0.001)

    /// Read on every change, so a Reduce Motion toggled mid-session is
    /// honoured on the next pull. Injected by the tests.
    var reducesMotion: @MainActor () -> Bool = { UIAccessibility.isReduceMotionEnabled }

    private(set) var isArmed = false

    /// The capsule. Its `bounds` and `center` are set by hand (see the type's
    /// doc) and its `transform` carries only the arming pop.
    private let capsule = UIView()

    // Resting ink: grey on the capsule's translucent fill.
    private let restingContent = UIView()
    private let ringTrack = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let restingGlyph = UIImageView()
    private let pullText = UIView()
    private let pullLabel = UILabel()

    // Armed ink: the inverted capsule, revealed through `bloom`.
    private let armedContent = UIView()
    private let bloom = UIView()
    private let armedGlyph = UIImageView()
    private let releaseText = UIView()
    private let releaseLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // Not an accessibility element: the gesture has a button twin (the
        // magnifier in the bar), which is the path VoiceOver takes.
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        alpha = 0

        capsule.layer.cornerRadius = Self.height / 2
        capsule.layer.cornerCurve = .continuous
        capsule.clipsToBounds = true
        capsule.backgroundColor = .secondarySystemFill
        addSubview(capsule)

        let glyphConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        for glyph in [restingGlyph, armedGlyph] {
            glyph.image = UIImage(systemName: "magnifyingglass", withConfiguration: glyphConfiguration)
            glyph.contentMode = .center
        }
        for label in [pullLabel, releaseLabel] {
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.adjustsFontForContentSizeCategory = true
        }
        pullLabel.text = Self.pullTitle
        releaseLabel.text = Self.releaseTitle

        for track in [ringTrack, ring] {
            track.fillColor = nil
            track.lineWidth = Self.ringWidth
            track.lineCap = .round
            restingContent.layer.addSublayer(track)
        }
        ring.strokeEnd = 0
        restingContent.addSubview(restingGlyph)
        pullText.addSubview(pullLabel)
        restingContent.addSubview(pullText)
        capsule.addSubview(restingContent)

        armedContent.addSubview(armedGlyph)
        releaseText.addSubview(releaseLabel)
        armedContent.addSubview(releaseText)
        bloom.backgroundColor = .black
        bloom.transform = Self.collapsedBloom
        armedContent.mask = bloom
        releaseText.alpha = 0
        armedContent.isHidden = true
        capsule.addSubview(armedContent)

        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (self: Self, _: UITraitCollection) in
            self.applyColors()
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _: UITraitCollection) in
            self.invalidateIntrinsicContentSize()
            self.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Geometry

    override var intrinsicContentSize: CGSize {
        CGSize(width: capsuleWidth(armed: true), height: Self.height)
    }

    private func textWidth(_ label: UILabel) -> CGFloat {
        ceil(label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: Self.height)).width)
    }

    private func capsuleWidth(armed: Bool) -> CGFloat {
        Self.leadingPadding + Self.ringDiameter + Self.spacing
            + textWidth(armed ? releaseLabel : pullLabel) + Self.trailingPadding
    }

    /// The ring's centre, in the capsule's space: fixed from its leading
    /// edge, so the glyph, the ring and the flood's origin never part.
    private var ringCenter: CGPoint {
        CGPoint(x: Self.leadingPadding + Self.ringDiameter / 2, y: Self.height / 2)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Setting the model values an in-flight animation is already heading
        // for leaves that animation alone, so a layout pass mid-spring is
        // harmless.
        layoutCapsule()

        let center = ringCenter
        let glyphFrame = CGRect(
            x: center.x - Self.ringDiameter / 2, y: 0, width: Self.ringDiameter, height: Self.height
        )
        restingGlyph.frame = glyphFrame
        armedGlyph.frame = glyphFrame

        let textX = Self.leadingPadding + Self.ringDiameter + Self.spacing
        for (container, label) in [(pullText, pullLabel), (releaseText, releaseLabel)] {
            container.frame = CGRect(x: textX, y: 0, width: textWidth(label), height: Self.height)
            label.frame = container.bounds
        }

        // The flood is a circle centred on the glyph, big enough to reach the
        // far corner of the WIDEST capsule when unscaled.
        let reach = hypot(capsuleWidth(armed: true) - center.x, Self.height / 2) + 1
        bloom.bounds = CGRect(x: 0, y: 0, width: reach * 2, height: reach * 2)
        bloom.center = center
        bloom.layer.cornerRadius = reach

        // Sublayers of a view's layer animate implicitly; the meter must
        // track the finger, not trail it by a quarter second.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let radius = (Self.ringDiameter - Self.ringWidth) / 2
        let path = UIBezierPath(
            arcCenter: center, radius: radius, startAngle: -.pi / 2, endAngle: 3 * .pi / 2, clockwise: true
        ).cgPath
        ringTrack.path = path
        ring.path = path
        CATransaction.commit()
    }

    /// The capsule's width for the current state, centred in the view; the
    /// two ink layers follow it.
    private func layoutCapsule() {
        let width = capsuleWidth(armed: isArmed)
        capsule.bounds = CGRect(x: 0, y: 0, width: width, height: Self.height)
        capsule.center = CGPoint(x: bounds.midX, y: bounds.midY)
        restingContent.frame = capsule.bounds
        armedContent.frame = capsule.bounds
    }

    private func applyColors() {
        let restingInk = UIColor.secondaryLabel
        restingGlyph.tintColor = restingInk
        pullLabel.textColor = restingInk
        // Layer colours do not follow the appearance on their own.
        ringTrack.strokeColor = UIColor.tertiaryLabel.resolvedColor(with: traitCollection).cgColor
        // The meter is drawn in the ink the armed capsule is FILLED with, so
        // the full ring and the flood that grows out of it read as one thing.
        ring.strokeColor = UIColor.label.resolvedColor(with: traitCollection).cgColor
        // `.label` on `.systemBackground` when armed: the header's own ink
        // (every bar glyph is tinted `.label`), inverted — legible in light
        // and dark alike, and nothing like the resting fill.
        armedContent.backgroundColor = .label
        armedGlyph.tintColor = .systemBackground
        releaseLabel.textColor = .systemBackground
    }

    // MARK: - Driving

    /// Places, fades and fills the capsule for a pull of `distance`.
    ///
    /// The view is pinned just under the bar; this only TRANSFORMS it and
    /// moves the ring's stroke, so a per-frame offset change never costs a
    /// layout pass.
    func setPull(distance: CGFloat, threshold: CGFloat) {
        let progress = min(max(distance / threshold, 0), 1)
        // Invisible for the first few points, then fully in well before the
        // line — the capsule has to have ARRIVED before it can arm.
        alpha = min(max((distance - Self.deadZone) / (threshold * 0.55), 0), 1)
        let scale = reducesMotion() ? 1 : 0.7 + 0.3 * progress
        // Centred in the gap once the gap can hold it; pinned at the top until
        // then, so it emerges from under the bar rather than out of nowhere.
        let lift = max(0, (distance - Self.height) / 2)
        transform = CGAffineTransform(translationX: 0, y: lift).scaledBy(x: scale, y: scale)

        // The meter runs over the part of the pull where the capsule shows:
        // empty as it appears, full exactly at the line.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.strokeEnd = min(max((distance - Self.deadZone) / (threshold - Self.deadZone), 0), 1)
        CATransaction.commit()
    }

    /// Arms or disarms the capsule — animated, and reversible at any point
    /// of the animation (every block starts from what is on screen).
    func setArmed(_ armed: Bool) {
        guard armed != isArmed else { return }
        isArmed = armed
        if reducesMotion() {
            crossfade(armed: armed)
        } else {
            flood(armed: armed)
        }
    }

    /// The full motion: the ink floods out of the glyph (or drains back into
    /// it), the words crossfade under it, the capsule re-fits and pops.
    private func flood(armed: Bool) {
        // Coming from a Reduce Motion crossfade, the inverted layer may be
        // faded out with the flood already open: close the flood first,
        // unseen, so the growth starts from the glyph.
        if armedContent.alpha < 1 {
            UIView.performWithoutAnimation {
                bloom.transform = Self.collapsedBloom
                armedContent.alpha = 1
            }
        }
        let options: UIView.AnimationOptions = [.beginFromCurrentState, .allowUserInteraction]
        // ⚠️ The closed flood is still a circle a fraction of a point wide,
        // and it DRAWS: a dark speck in the middle of the magnifier. The
        // inverted layer is hidden whenever the flood is fully drained.
        armedContent.isHidden = false
        if armed {
            // In on a spring with a little bounce: the arrival is an event.
            UIView.animate(
                springDuration: 0.45, bounce: 0.15, initialSpringVelocity: 0, delay: 0, options: options
            ) {
                self.bloom.transform = .identity
                self.layoutCapsule()
            }
        } else {
            // Out on an accelerating curve, not a spring: a retreat that
            // wobbled would read as indecision, and a spring's long tail left
            // a shrinking black disk sitting on the glyph for a dozen frames
            // (seen in a 30 fps recording). Ease-in lands, and is gone.
            UIView.animate(withDuration: 0.22, delay: 0, options: options.union(.curveEaseIn)) {
                self.bloom.transform = Self.collapsedBloom
                self.layoutCapsule()
            } completion: { _ in
                // Only if nothing re-armed it while it drained.
                if !self.isArmed { self.armedContent.isHidden = true }
            }
        }
        // The words swap quickly — the new ones must be readable while the
        // flood is still settling. The outgoing "Pull" goes FAST: the flood
        // crosses the capsule in about 150 ms, and a slower fade left grey
        // "…ll to search" beside the inverted "Re…" at the wavefront.
        UIView.animate(withDuration: armed ? 0.1 : 0.2, delay: 0, options: options.union(.curveEaseOut)) {
            self.pullText.alpha = armed ? 0 : 1
        }
        UIView.animate(withDuration: 0.22, delay: armed ? 0.05 : 0, options: options.union(.curveEaseOut)) {
            self.releaseText.alpha = armed ? 1 : 0
        }
        guard armed else { return }
        // The pop: a quick swell and a springy settle, in time with the
        // haptic. Only on arming — disarming is quiet, like its haptic.
        UIView.animate(withDuration: 0.1, delay: 0, options: options.union(.curveEaseOut)) {
            self.capsule.transform = CGAffineTransform(scaleX: 1.06, y: 1.06)
        } completion: { _ in
            UIView.animate(
                springDuration: 0.4, bounce: 0.35, initialSpringVelocity: 0, delay: 0, options: options
            ) {
                self.capsule.transform = .identity
            }
        }
    }

    /// Reduce Motion: the inverted capsule fades in or out in place; nothing
    /// grows, bounces or pops. The width still has to change — the longer
    /// words need it — so it eases, briefly.
    private func crossfade(armed: Bool) {
        armedContent.isHidden = false
        if bloom.transform != .identity {
            UIView.performWithoutAnimation {
                if armed { armedContent.alpha = 0 }
                bloom.transform = .identity
            }
        }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.capsule.transform = .identity
            self.armedContent.alpha = armed ? 1 : 0
            self.pullText.alpha = armed ? 0 : 1
            self.releaseText.alpha = armed ? 1 : 0
            self.layoutCapsule()
        }
    }

    #if DEBUG
    /// The words the capsule is showing — the armed ones once armed.
    var debugLabelText: String? { isArmed ? releaseLabel.text : pullLabel.text }
    /// How full the meter is (model value), 0…1.
    var debugRingProgress: CGFloat { ring.strokeEnd }
    /// The flood's model scale: ~0 closed, 1 covering the capsule.
    var debugBloomScale: CGFloat { bloom.transform.a }
    /// The inverted layer's model alpha — what Reduce Motion fades.
    var debugArmedAlpha: CGFloat { armedContent.isHidden ? 0 : armedContent.alpha }
    /// The capsule's model width.
    var debugCapsuleWidth: CGFloat { capsule.bounds.width }
    /// The capsule's width in either state, for the tests' comparisons.
    func debugCapsuleWidth(armed: Bool) -> CGFloat { capsuleWidth(armed: armed) }
    #endif
}
