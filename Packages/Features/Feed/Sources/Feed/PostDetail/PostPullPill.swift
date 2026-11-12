import DesignSystem
import MediaCore
import UIKit

/// The pull to the next / previous post's pill (#2298 § 2): a small Liquid
/// Glass capsule coming out of the stream's edge, the target post's author
/// in a ring that fills with the pull.
///
/// ```
///   ( (◔) Next post )                     out of the edge, the ring filling
///   ( (●) Release for the next post )     the threshold: full, one tick
/// ```
///
/// ⚠️ IT FOLLOWS THE PULL, FRAME BY FRAME, BOTH WAYS (#2349, the owner
/// 2026-11-12) — nothing timed but the threshold's swell and the words'
/// change:
///
/// - **Its size is the pull's** (`PostPullRule.pillScale`): from about 0.6
///   of its own where it comes out to 1 at the threshold, never taller than
///   the gap the pull opens, so it is never over the rows' words. Its foot
///   stays where the host stands it (16 pt above the composer): it grows
///   away from the edge and shrinks back toward it, never sliding into it.
///   Released short, it follows the content's spring back and is gone at
///   `appearLift`. (#2298's timed pop from half size, played each time the
///   pull crossed 8 pt, jumped on a wavering pull and slid into the composer
///   on a cancel.)
/// - **The glass materialises through its effect and sizes through its
///   frame**, never `alpha` or a transform (#2166, `SnapGlassColumn`'s
///   findings); the avatar, the ring and the words are scaled with a
///   transform (they are not glass) and come in with the pull
///   (`PostPullRule.contentPresence`).
/// - **At the threshold:** a small swell (`PostPullRule.swell`, then back
///   to 1) with the app's threshold haptic (`PullThresholdFeedback`, the
///   `armed` role), once per crossing.
/// - **⚠️ The words are never clipped:** to longer words the capsule widens
///   first, then the words cross-fade; to shorter ones they cross-fade
///   first, then it narrows. Each label is laid out at its own width, never
///   the capsule's, so no frame shows a cut word.
/// - **Reduce Motion:** no scale and no swell; the pill appears and goes
///   with a fade at `appearLift`, the words cross-fade, and the ring does not
///   fill with the pull — empty, then full at the threshold.
///
/// The host gives it a box as wide as the pill may grow and `height` tall,
/// its foot (`.next`) or its head (`.previous`) on the box's edge; the
/// capsule is drawn inside, centred, anchored there.
///
/// It takes no touches: it is the pull's answer, never a control.
@MainActor
final class PostPullPill: UIView {
    static let height: CGFloat = 40
    private static let avatarDiameter: CGFloat = 26
    private static let ringDiameter: CGFloat = 32
    private static let ringWidth: CGFloat = 2.5
    /// The ring's inset from the capsule's leading edge.
    private static let leadingInset = (height - ringDiameter) / 2
    /// The words' leading edge in the capsule.
    private static let wordsX = leadingInset + ringDiameter + Spacing.sm
    /// After the words.
    private static let trailingInset = Spacing.md

    /// The words' change: the capsule's width approaches its words' with this
    /// time constant (about 0.14 s to arrive), and the words cross-fade over
    /// `fadeDuration`.
    private static let widthTimeConstant: Double = 0.045
    private static let fadeDuration: Double = 0.12
    /// The threshold's swell: up and back over this long.
    private static let swellDuration: Double = 0.32

    private(set) var direction: PostPullDirection = .next
    private(set) var isArmed = false
    /// The glass is out (materialised, or on its way).
    private(set) var isShown = false
    /// 0…1, as the ring draws it.
    private(set) var progress: CGFloat = 0
    /// The size the pull gives the pill, a fraction of its own: 0 gone.
    private(set) var scale: CGFloat = 0

    private let glass = UIVisualEffectView(effect: nil)
    /// The avatar, the ring and the words, scaled as one with the capsule.
    private let content = UIView()
    private let avatar = AvatarView(diameter: PostPullPill.avatarDiameter, size: .avatar)
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    /// "Next post" / "Previous post".
    private let restingLabel = UILabel()
    /// "Release for the next post" / "… the previous post".
    private let armedLabel = UILabel()
    private let feedback = PullThresholdFeedback()
    private let reducesMotion: () -> Bool

    /// The room the words have in the capsule, unscaled: it never holds less
    /// than the words that show (`step`).
    private var wordsWidth: CGFloat = 0
    /// 0 the resting words, 1 the armed words: the cross-fade.
    private var wordsMix: CGFloat = 0
    /// The content's opacity for the pull.
    private var presence: CGFloat = 0
    /// Since the swell began, nil when there is none.
    private var swellElapsed: Double?
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval?

    init(reducesMotion: @escaping () -> Bool = { MotionPreference.reducesMotion }) {
        self.reducesMotion = reducesMotion
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        // The pill is read with the page, not as an element of its own: the
        // page's custom actions say the same without a pull.
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        glass.clipsToBounds = true
        glass.cornerConfiguration = .capsule()
        addSubview(glass)
        glass.contentView.addSubview(content)
        for layer in [track, ring] {
            layer.fillColor = UIColor.clear.cgColor
            layer.lineWidth = Self.ringWidth
            layer.lineCap = .round
            content.layer.addSublayer(layer)
        }
        track.strokeColor = UIColor.tertiaryLabel.cgColor
        ring.strokeColor = UIColor.label.cgColor
        ring.strokeEnd = 0
        content.addSubview(avatar)
        for label in [restingLabel, armedLabel] {
            label.font = .scaledFont(forTextStyle: .subheadline, weight: .semibold)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .label
            // Never an ellipsis: words longer than the screen allows (the
            // largest text sizes) shrink to fit instead.
            label.lineBreakMode = .byClipping
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.6
            content.addSubview(label)
        }
        content.alpha = 0
        applyWords()
        settleWords()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (pill: PostPullPill, _) in
            pill.resolveInk()
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (pill: PostPullPill, _) in
            pill.settleWords()
            pill.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The ring's ink, resolved for the pill's style (layers hold no dynamic
    /// colour).
    private func resolveInk() {
        track.strokeColor = UIColor.tertiaryLabel.resolvedColor(with: traitCollection).cgColor
        ring.strokeColor = UIColor.label.resolvedColor(with: traitCollection).cgColor
    }

    /// The pull's target: its direction and its author.
    func configure(direction: PostPullDirection, target: PostPullTarget, pipeline: ImagePipeline?) {
        self.direction = direction
        avatar.setMonogram(target.monogram)
        avatar.setPicture(target.avatarURL, pipeline: pipeline)
        isArmed = false
        applyWords()
        settleWords()
        setNeedsLayout()
    }

    /// The words for the state: "Next post", then "Release for the next post".
    static func words(_ direction: PostPullDirection, armed: Bool) -> String {
        switch (direction, armed) {
        case (.next, false): "Next post"
        case (.next, true): "Release for the next post"
        case (.previous, false): "Previous post"
        case (.previous, true): "Release for the previous post"
        }
    }

    private func applyWords() {
        restingLabel.text = Self.words(direction, armed: false)
        armedLabel.text = Self.words(direction, armed: true)
    }

    // MARK: - Measures

    /// A label's words' own width, held to what the box allows (past it,
    /// the label shrinks them to fit).
    private func measuredWords(of label: UILabel) -> CGFloat {
        let natural = ((label.text ?? "") as NSString).size(withAttributes: [.font: label.font as Any]).width.rounded(.up)
        guard bounds.width > 0 else { return natural }
        return min(natural, max(0, bounds.width - Self.wordsX - Self.trailingInset))
    }

    private var restingWordsWidth: CGFloat { measuredWords(of: restingLabel) }
    private var armedWordsWidth: CGFloat { measuredWords(of: armedLabel) }

    /// The capsule's width, at its own size, for words `words` wide.
    private static func capsuleWidth(words: CGFloat) -> CGFloat {
        (wordsX + words + trailingInset).rounded(.up)
    }

    /// The pill's width at its own size for its words now, held to `limit`.
    func width(limit: CGFloat) -> CGFloat {
        let words = isArmed ? armedWordsWidth : restingWordsWidth
        return min(limit, Self.capsuleWidth(words: words))
    }

    /// The swell's factor now: up to `PostPullRule.swell` and back.
    private var swellFactor: CGFloat {
        guard let elapsed = swellElapsed, elapsed < Self.swellDuration else { return 1 }
        return 1 + (PostPullRule.swell - 1) * CGFloat(sin(Double.pi * elapsed / Self.swellDuration))
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        // No change under way: the capsule at its words' width as the box
        // now measures them (a new box, a new text size).
        if link == nil, !manualClock, wordsMix == (isArmed ? 1 : 0) {
            wordsWidth = isArmed ? armedWordsWidth : restingWordsWidth
        }
        let k = scale * swellFactor
        let fullWidth = Self.capsuleWidth(words: wordsWidth)
        let size = CGSize(width: fullWidth * k, height: Self.height * k)
        // Anchored at its foot (the next post: on the box's bottom edge) or
        // its head (the previous: the top), so it grows away from the edge.
        let y = direction == .next ? bounds.height - size.height : 0
        glass.frame = CGRect(x: (bounds.width - size.width) / 2, y: y, width: size.width, height: size.height)
        content.transform = .identity
        content.bounds = CGRect(x: 0, y: 0, width: fullWidth, height: Self.height)
        content.center = CGPoint(x: size.width / 2, y: size.height / 2)
        content.transform = CGAffineTransform(scaleX: max(k, 0.001), y: max(k, 0.001))
        content.alpha = reducesMotion() ? content.alpha : presence

        let ringFrame = CGRect(x: Self.leadingInset, y: (Self.height - Self.ringDiameter) / 2,
                               width: Self.ringDiameter, height: Self.ringDiameter)
        let avatarSide = Self.avatarDiameter
        avatar.frame = CGRect(x: ringFrame.midX - avatarSide / 2, y: ringFrame.midY - avatarSide / 2,
                              width: avatarSide, height: avatarSide)
        // The ring starts at twelve o'clock and runs clockwise.
        let radius = (Self.ringDiameter - Self.ringWidth) / 2
        let path = UIBezierPath(
            arcCenter: CGPoint(x: ringFrame.midX, y: ringFrame.midY), radius: radius,
            startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true
        ).cgPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.path = path
        ring.path = path
        resolveInk()
        CATransaction.commit()
        // Each label at its own words' width, never the capsule's: the
        // capsule always holds the words that show (`step`).
        restingLabel.frame = CGRect(x: Self.wordsX, y: 0, width: restingWordsWidth, height: Self.height)
        armedLabel.frame = CGRect(x: Self.wordsX, y: 0, width: armedWordsWidth, height: Self.height)
        restingLabel.alpha = 1 - wordsMix
        armedLabel.alpha = wordsMix
    }

    // MARK: - The pull

    /// Re-reads the pull: the size and the content's presence for the pulled
    /// distance, the glass out past `appearLift`, the ring filling toward the
    /// threshold, the words, the swell and the tick at it.
    ///
    /// `room`: the height the gap leaves the pill between its foot's place
    /// and the rows (`PostPullRule.pillScale`); nil when unbounded (tests).
    func apply(_ reading: PostPullTracker.Reading, room: CGFloat? = nil) {
        let reduced = reducesMotion()
        progress = reading.progress
        if reduced {
            scale = reading.isShown ? 1 : 0
        } else {
            scale = PostPullRule.pillScale(pulled: reading.pulled, room: room ?? .greatestFiniteMagnitude, height: Self.height)
            presence = PostPullRule.contentPresence(pulled: reading.pulled)
        }
        setShown(reading.isShown && scale > 0)
        if reading.isArmed != isArmed {
            isArmed = reading.isArmed
            if isArmed, !reduced { swellElapsed = 0 }
            if !isArmed { swellElapsed = nil }
            startMotion()
        }
        // The tick: once per crossing into the armed state, never on a bounce
        // (the tracker arms only under the finger).
        feedback.update(pulled: isArmed ? 1 : 0, threshold: 1, isTracking: isArmed)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.strokeEnd = reduced ? (isArmed ? 1 : 0) : (isArmed ? 1 : progress)
        CATransaction.commit()
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// The pull went home or has nowhere to go: the pill is gone. (Pulled
    /// back to `appearLift`, it is already at its smallest.)
    func retract() {
        guard isShown || isArmed || scale > 0 else { return }
        isArmed = false
        scale = 0
        presence = 0
        settleWords()
        feedback.update(pulled: 0, threshold: 1, isTracking: false)
        setShown(false)
        setNeedsLayout()
    }

    /// Readies the tick, as a pull begins.
    func prepare() { feedback.prepare() }

    /// Gone at once (a commit's page has left, the stream reset).
    func clear() {
        isShown = false
        isArmed = false
        progress = 0
        scale = 0
        presence = 0
        settleWords()
        glass.layer.removeAllAnimations()
        content.layer.removeAllAnimations()
        glass.effect = nil
        content.alpha = 0
        ring.strokeEnd = 0
        feedback.update(pulled: 0, threshold: 1, isTracking: false)
        setNeedsLayout()
    }

    /// The glass out or gone, through its effect — materialised and
    /// dematerialised by the system, never faded through `alpha` (#2166).
    /// Under Reduce Motion the content fades with it.
    private func setShown(_ show: Bool) {
        guard show != isShown else { return }
        isShown = show
        let reduced = reducesMotion()
        // Never materialised off a window (#46): `didMoveToWindow` does it.
        guard window != nil else {
            glass.effect = nil
            if reduced { content.alpha = show ? 1 : 0 }
            return
        }
        let effect: UIVisualEffect? = show ? Self.makeGlass() : nil
        UIView.animate(withDuration: show ? 0.25 : 0.2, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.glass.effect = effect
            if reduced { self.content.alpha = show ? 1 : 0 }
        }
    }

    private static func makeGlass() -> UIGlassEffect {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = false
        return effect
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopMotion()
            settleWords()
            glass.effect = nil
        } else if isShown, glass.effect == nil {
            glass.effect = Self.makeGlass()
        }
    }

    // MARK: - The words' change and the swell, stepped frame by frame

    /// The words at their end state at once: the capsule at their width.
    private func settleWords() {
        wordsMix = isArmed ? 1 : 0
        wordsWidth = isArmed ? armedWordsWidth : restingWordsWidth
        swellElapsed = nil
    }

    /// Whether the words or the swell are still on their way.
    private var isMoving: Bool {
        let settledWidth = isArmed ? armedWordsWidth : restingWordsWidth
        return wordsMix != (isArmed ? 1 : 0) || abs(wordsWidth - settledWidth) > 0.01 || swellElapsed != nil
    }

    /// Advances the words' change and the swell by `dt` seconds.
    ///
    /// ⚠️ THE INVARIANT: the capsule's room for words (`wordsWidth`) is never
    /// less than the words that show — the armed words show (`wordsMix > 0`)
    /// only once it holds them, and it narrows only once they are gone.
    func step(_ dt: Double) {
        let instant = reducesMotion()
        let resting = restingWordsWidth, armed = armedWordsWidth
        func approach(_ value: CGFloat, _ target: CGFloat) -> CGFloat {
            guard !instant else { return target }
            let next = value + (target - value) * CGFloat(1 - exp(-dt / Self.widthTimeConstant))
            return abs(target - next) < 0.5 ? target : next
        }
        let fade = CGFloat(dt / Self.fadeDuration)
        if isArmed {
            if wordsWidth < armed {
                // Widen first, the resting words still showing.
                wordsWidth = approach(wordsWidth, armed)
            } else {
                wordsWidth = max(armed, approach(wordsWidth, armed))
                wordsMix = min(1, wordsMix + fade)
            }
        } else if wordsMix > 0 {
            // The long words go first, in a capsule that still holds them.
            wordsMix = max(0, wordsMix - fade)
        } else {
            wordsWidth = max(resting, approach(wordsWidth, resting))
        }
        if let elapsed = swellElapsed {
            let next = elapsed + dt
            swellElapsed = next < Self.swellDuration ? next : nil
        }
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// Whether a test steps the words' change itself.
    private var manualClock: Bool {
        #if DEBUG
        debugManualClock
        #else
        false
        #endif
    }

    private func startMotion() {
        guard isMoving, !manualClock else { return }
        // Off a window nothing is seen: the end state at once.
        guard window != nil else {
            settleWords()
            setNeedsLayout()
            return
        }
        guard link == nil else { return }
        lastTick = nil
        let displayLink = CADisplayLink(target: PostPullPillTicker(self), selector: #selector(PostPullPillTicker.tick(_:)))
        displayLink.add(to: .main, forMode: .common)
        link = displayLink
    }

    private func stopMotion() {
        link?.invalidate()
        link = nil
        lastTick = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = lastTick.map { min(max(0, now - $0), 0.05) } ?? (1.0 / 60)
        lastTick = now
        step(dt)
        if !isMoving { stopMotion() }
    }

    #if DEBUG
    /// The words the pill says now (the end state of a change under way).
    var debugLine: String? { isArmed ? armedLabel.text : restingLabel.text }
    var debugRingFill: CGFloat { ring.strokeEnd }
    /// The capsule's frame in the pill's box.
    var debugGlassFrame: CGRect { glass.frame }
    /// The content's opacity.
    var debugPresence: CGFloat { content.alpha }
    /// Whether the glass's effect is on (materialised or on its way).
    var debugHasGlass: Bool { glass.effect != nil }
    /// The words' change is stepped only by `step`. Tests.
    var debugManualClock = false

    /// Every label that shows (any opacity) lies inside the capsule, at its
    /// words' own width: no frame shows a cut word.
    var debugWordsFitTheCapsule: Bool {
        layoutIfNeeded()
        for label in [restingLabel, armedLabel] where label.alpha > 0.001 {
            let natural = measuredWords(of: label)
            guard label.bounds.width + 0.5 >= natural else { return false }
            let inCapsule = label.convert(label.bounds, to: glass)
            guard glass.bounds.insetBy(dx: -0.5, dy: -0.5).contains(inCapsule) else { return false }
        }
        return true
    }

    /// The words that show, with their opacity.
    var debugShownWords: [(String, CGFloat)] {
        [restingLabel, armedLabel].filter { $0.alpha > 0.001 }.map { ($0.text ?? "", $0.alpha) }
    }
    #endif
}

/// Holds the pill for its display link without keeping it alive.
@MainActor
private final class PostPullPillTicker: NSObject {
    weak var pill: PostPullPill?
    init(_ pill: PostPullPill) { self.pill = pill }

    @objc func tick(_ link: CADisplayLink) {
        guard let pill else { return link.invalidate() }
        pill.tick(link)
    }
}
