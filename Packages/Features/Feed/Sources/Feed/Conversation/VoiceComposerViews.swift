import DesignSystem
import ThreadKit
import UIKit
import VoiceKitUI

/// The field's place while a voice message is recorded (#2102). Locked
/// and paused, the time leads on its chip and the waveform fills the rest
/// of the field, and the bin stands in the avatar's place
/// (`CommentsInputBar.showVoiceDelete`) — Telegram's (the owner,
/// 2026-11-06; the chip left the bars' middle for the field's start on
/// 11-07):
///
/// ```
/// recording   ● 0:07   ‹ Slide to cancel
/// locked      [● 0:42] ▁▂▅▇▅▃▂▁▃▆▇▅▃   (❚❚)  (↑)
/// paused      [▶︎ 0:42] ▂▅▇▅▃▂▅▇▆▃▂▅   (🎙)  (↑)
/// ```
///
/// A voice post's composer (#2209) writes its time in seconds — `● 7″`,
/// `-7″` in red for the last ten — as every voice post's timer does
/// (`timerStyle`, #2294).
///
/// The 🎙 stays on the paused bar even after a listen back: it records on
/// from where the take ended (the owner, 2026-11-08).
final class VoiceRecordingStrip: UIView {
    enum Mode: Equatable {
        case recording
        case locked
        case paused(resumable: Bool, playing: Bool)
    }

    var onPause: (() -> Void)?
    var onResume: (() -> Void)?
    var onPlay: (() -> Void)?
    var onSend: (() -> Void)?
    var onSeek: ((Double) -> Void)?

    private(set) var mode: Mode = .recording
    /// How the take's time is written (#2294): a voice message's clock
    /// (`0:12`), a voice post's seconds (`12″`) — the composer's to say.
    var timerStyle: VoiceView.TimerStyle = .clock {
        didSet {
            guard timerStyle != oldValue, let shown = shownTime else { return }
            setTime(shown.seconds, remaining: shown.remaining)
        }
    }
    /// The time last shown, written again in a new style.
    private var shownTime: (seconds: TimeInterval, remaining: TimeInterval?)?
    private let dot = UIView()
    private let timerLabel = UILabel()
    private let slideLabel = UILabel()
    /// The waveform's box: it stretches between the chip and the buttons.
    private let box = UIView()
    let waveform = WaveformBars()
    private let chip = UIButton(configuration: .gray())
    /// ❚❚ while it records, 🎙 once paused: ONE button whose symbol is
    /// replaced (the owner, 2026-11-07: an icon turning into another is
    /// always the symbol's own Replace) — the app's play ⇄ pause swap
    /// (`PlayPauseGlyph`, #2276), the owner's pause.
    private let takeButton = VoiceRecordingStrip.button(AppSymbol.pause.rawValue, label: "Pause recording")
    private let sendButton = VoiceRecordingStrip.button("arrow.up.circle.fill", label: "Send voice message")
    private let stack = UIStackView()
    private var liveLevels: [UInt8] = []
    /// What the bars draw: the take recording now, or the one listened back.
    private enum WaveformSource { case live, take }
    private var waveformSource: WaveformSource?
    private var timeText = ""
    private var stackTrailing: NSLayoutConstraint?
    /// The chip as wide as its widest face for its time: ▶︎, ❚❚ and ● are not
    /// the same width, and the chip jumped by a fraction of a point at each
    /// play and pause (2026-11-08).
    private var chipWidth: NSLayoutConstraint?
    private var chipWidthTitle = ""
    /// The chip's three faces: the recording dot, the owner's play and
    /// pause (#2276).
    private static let chipFaces = ["circle.fill", AppSymbol.play.rawValue, AppSymbol.pause.rawValue]
    /// The faces shown, by name — a repeat of the same face swaps nothing.
    private var shownTakeFace = AppSymbol.pause.rawValue
    private var shownChipFace = ""
    /// Holding, the mic disc stands over the field's end — its glow wider
    /// still: the hint stops short of it (the owner, 2026-11-07: covered
    /// before the finger had moved).
    static let discClearance: CGFloat = 40

    override init(frame: CGRect) {
        super.init(frame: frame)
        dot.backgroundColor = .systemRed
        dot.layer.cornerRadius = 4
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        timerLabel.font = .scaledMonospacedDigitSystemFont(ofSize: UIFont.defaultPointSize(for: .body), relativeTo: .body)
        timerLabel.adjustsFontForContentSizeCategory = true
        timerLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        slideLabel.text = "‹ Slide to cancel"
        slideLabel.font = .appFont(forTextStyle: .subheadline)
        slideLabel.adjustsFontForContentSizeCategory = true
        slideLabel.textColor = .secondaryLabel
        slideLabel.lineBreakMode = .byTruncatingTail
        sendButton.configuration?.baseForegroundColor = Palette.tint

        // The chip: the time, leading the field, the bubble's speed chip's
        // look.
        chip.configuration?.cornerStyle = .capsule
        chip.configuration?.baseBackgroundColor = .systemGray5
        chip.configuration?.baseForegroundColor = .label
        chip.configuration?.imagePadding = 4
        chip.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 9)
        chip.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        chip.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .scaledMonospacedDigitSystemFont(
                ofSize: UIFont.defaultPointSize(for: .footnote), weight: .semibold, relativeTo: .footnote
            )
            return attributes
        }
        chip.addAction(UIAction { [weak self] _ in
            guard case .paused = self?.mode else { return }
            self?.onPlay?()
        }, for: .primaryActionTriggered)

        waveform.onSeek = { [weak self] fraction, _ in self?.onSeek?(fraction) }
        // The bars fill the field (the bubble's hug them): they, not the
        // buttons, take the room — and give it up first. Their own width
        // (`intrinsicContentSize`, as wide as their bars) once squeezed the
        // pause under the send (the owner's video, 2026-11-07).
        waveform.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        waveform.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
        waveform.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(waveform)
        NSLayoutConstraint.activate([
            waveform.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            waveform.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            waveform.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            waveform.heightAnchor.constraint(equalToConstant: 24),
            box.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ])
        chip.setContentCompressionResistancePriority(.required, for: .horizontal)
        let width = chip.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        width.isActive = true
        chipWidth = width
        // The one part that stretches, and the one that gives: the buttons
        // keep their size.
        box.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        box.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)

        takeButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if mode == .locked { onPause?() } else { onResume?() }
        }, for: .primaryActionTriggered)
        sendButton.addAction(UIAction { [weak self] _ in self?.onSend?() }, for: .primaryActionTriggered)

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = Spacing.sm
        for part in [dot, timerLabel, slideLabel, chip, box, takeButton, sendButton] as [UIView] {
            stack.addArrangedSubview(part)
        }
        stack.setCustomSpacing(Spacing.xs, after: dot)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let trailing = stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        stackTrailing = trailing
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            trailing,
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        apply(.recording)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func button(_ symbol: String, label: String) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage.symbol(named: symbol)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        configuration.baseForegroundColor = .label
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label
        return button
    }

    /// - Parameter animated: a change in sight springs — the parts that come
    ///   fade in as the row opens for them, the parts that go fade out as it
    ///   closes (the owner, 2026-11-07: the hint, the time, the buttons).
    ///
    /// ⚠️ ONLY THE ROW SPRINGS (the owner's video, 2026-11-08). The buttons'
    /// faces (the chip's ▶︎ / ❚❚ and its time, the take's ❚❚ / 🎙) change and
    /// lay out with no animation, so the symbol's own Replace runs alone:
    /// laid out inside the spring, the chip's time flew in from its bottom
    /// right and the symbol stuttered under a moving frame. And a change
    /// that shows or hides nothing (▶︎ to ❚❚) does not spring at all.
    func apply(_ mode: Mode, animated: Bool = false) {
        let springs = animated && window != nil && !MotionPreference.reducesMotion && mode != self.mode
        let shownBefore = Dictionary(uniqueKeysWithValues: animatedParts.map { (ObjectIdentifier($0), !$0.isHidden) })
        let trailingBefore = stackTrailing?.constant ?? 0
        self.mode = mode
        let recording = mode == .recording
        // A new take starts from empty bars (recording on from a closed take
        // goes straight to locked, and keeps them).
        if recording {
            liveLevels = []
            waveformSource = nil
        }
        let locked = mode == .locked
        let paused: Bool, resumable: Bool, playing: Bool
        if case .paused(let canResume, let isPlaying) = mode {
            paused = true; resumable = canResume; playing = isPlaying
        } else {
            paused = false; resumable = false; playing = false
        }
        // Holding: the dot, the time and the hint. Locked or paused: the
        // bars with the time on their chip.
        dot.isHidden = !recording
        timerLabel.isHidden = !recording
        slideLabel.isHidden = !recording
        box.isHidden = recording
        chip.isHidden = recording
        stackTrailing?.constant = recording ? -Self.discClearance : 0
        // Replaced only in sight: a button coming into view shows its symbol
        // at once. Paused, the 🎙 records on — resumed, or after a listen
        // back from the take's end (`resumable` false).
        let wasShown = !takeButton.isHidden
        takeButton.isHidden = !(locked || paused)
        sendButton.isHidden = recording
        // The faces swap by the app's play ⇄ pause swap (#2276), in sight
        // only, before the row's layout: the scale and fade and the
        // cross-fade are view animations, which no `performWithoutAnimation`
        // may hold.
        let takeFace = locked ? AppSymbol.pause.rawValue : "mic.fill"
        if takeFace != shownTakeFace {
            shownTakeFace = takeFace
            let take = UIImage.symbol(named: takeFace)
            PlayPauseGlyph.swap(takeButton, site: .voiceComposerTake, animated: wasShown && window != nil) {
                takeButton.configuration?.image = take
            }
        }
        // The chip leads with what it is: a red dot while it records,
        // ▶︎ / ❚❚ to listen back when it is paused.
        let chipFace = paused ? (playing ? AppSymbol.pause.rawValue : AppSymbol.play.rawValue) : "circle.fill"
        if chipFace != shownChipFace {
            let chipWasShown = shownBefore[ObjectIdentifier(chip)] ?? false
            shownChipFace = chipFace
            let face = UIImage.symbol(named: chipFace)
            PlayPauseGlyph.swap(chip, site: .voiceComposerChip, animated: chipWasShown && window != nil) {
                chip.configuration?.image = face
            }
        }
        UIView.performWithoutAnimation {
            chip.configuration?.imageColorTransformer = paused ? nil : UIConfigurationColorTransformer { _ in .systemRed }
            takeButton.layoutIfNeeded()
            chip.layoutIfNeeded()
        }
        takeButton.accessibilityLabel = locked ? "Pause recording" : (resumable ? "Resume recording" : "Record more")
        chip.isUserInteractionEnabled = paused
        chip.accessibilityLabel = paused ? (playing ? "Pause playback" : "Play recording") : nil
        chip.isAccessibilityElement = paused
        blink(recording || locked)
        let rowChanges = animatedParts.contains { (shownBefore[ObjectIdentifier($0)] ?? !$0.isHidden) == $0.isHidden }
            || trailingBefore != (stackTrailing?.constant ?? 0)
        guard springs, rowChanges else { return }
        #if DEBUG
        debugSpringCount += 1
        #endif
        // Undone, then sprung into: the parts as they were, the change in
        // one spring.
        let target = animatedParts.map { ($0, !$0.isHidden) }
        let targetTrailing = stackTrailing?.constant
        for (part, shown) in target {
            let was = shownBefore[ObjectIdentifier(part)] ?? shown
            part.isHidden = !was
            if !was, shown { part.alpha = 0 }
        }
        stackTrailing?.constant = trailingBefore
        layoutIfNeeded()
        stackTrailing?.constant = targetTrailing ?? 0
        UIView.animate(springDuration: 0.4, bounce: 0.1, options: [.allowUserInteraction, .beginFromCurrentState]) {
            for (part, shown) in target {
                part.isHidden = !shown
                part.alpha = shown ? 1 : 0
            }
            self.layoutIfNeeded()
        } completion: { _ in
            for (part, _) in target where part.isHidden { part.alpha = 1 }
        }
    }

    /// The parts a mode shows or hides.
    private var animatedParts: [UIView] { [dot, timerLabel, slideLabel, chip, box, takeButton, sendButton] }

    /// The take's time; red in its last ten seconds, counting down (#2102) —
    /// in the voice's own format (#2294): a message's "0:12" and "-0:07", a
    /// post's "12″" and "-7″".
    func setTime(_ seconds: TimeInterval, remaining: TimeInterval?) {
        let running = remaining.map { $0 <= 10 } ?? false
        let left = (remaining ?? 0).rounded(.up)
        let text = running
            ? "-" + ThreadVoiceView.timerText(left, style: timerStyle)
            : ThreadVoiceView.timerText(seconds, style: timerStyle)
        shownTime = (seconds, remaining)
        timerLabel.text = text
        timerLabel.textColor = running ? Palette.tint : .label
        timerLabel.accessibilityLabel = switch timerStyle {
        case .clock: "\(Int(seconds)) seconds"
        // A post's countdown says what is left (#2294): "7 seconds left".
        case .seconds: running
            ? ThreadVoiceView.spokenTime(left, style: .seconds) + " left"
            : ThreadVoiceView.spokenTime(seconds, style: .seconds)
        }
        // The chip's time and ink change with no animation, laid out at once:
        // set inside a spring, the title flew in from the chip's corner.
        UIView.performWithoutAnimation {
            if text != timeText {
                timeText = text
                chip.configuration?.title = text
                holdChipWidth(for: text)
            }
            chip.configuration?.baseForegroundColor = running ? Palette.tint : .label
            chip.layoutIfNeeded()
        }
    }

    /// The chip's least width: its widest face with this time, read once per
    /// time's shape (its digits as zeros), so it never moves on a face change.
    private func holdChipWidth(for text: String) {
        let shape = String(text.map { $0.isNumber ? "0" : $0 })
        guard shape != chipWidthTitle, let configuration = chip.configuration else { return }
        chipWidthTitle = shape
        let sizing = UIButton(configuration: configuration)
        var widest: CGFloat = 0
        for face in Self.chipFaces {
            sizing.configuration?.title = shape
            sizing.configuration?.image = UIImage.symbol(named: face)
            widest = max(widest, sizing.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width)
        }
        chipWidth?.constant = ceil(widest)
    }

    /// How far toward cancel the finger is: the hint fades with it.
    func setCancelProgress(_ progress: CGFloat) {
        slideLabel.alpha = 1 - progress
        slideLabel.transform = CGAffineTransform(translationX: -progress * 24, y: 0)
    }

    /// The locked bar's live waveform, scrolling: the newest level on the right.
    func appendLevel(_ level: Float) {
        liveLevels.append(UInt8(min(31, max(0, level * 31 * 2.2))))
        let width = max(1, waveform.bounds.width)
        let count = ThreadVoiceView.barCount(forWidth: width)
        let shown = Array(liveLevels.suffix(count))
        drawWaveform(.live) {
            self.waveform.configure(levels: Array(repeating: 0, count: max(0, count - shown.count)) + shown, barCount: count, progress: 0)
        }
    }

    /// The paused bar's whole take, `progress` of it played back.
    func showTake(levels: [UInt8], duration: TimeInterval, progress: Double) {
        let count = ThreadVoiceView.barCount(forWidth: max(1, waveform.bounds.width))
        drawWaveform(.take) { self.waveform.configure(levels: levels, barCount: count, progress: progress) }
        setTime(progress > 0 ? duration * progress : duration, remaining: nil)
    }

    /// The bars change source — the take listened back, the take recording
    /// on — cross-dissolving (the owner, 2026-11-08); the same source redraws
    /// at once, as it scrolls or plays.
    private func drawWaveform(_ source: WaveformSource, _ draw: @escaping () -> Void) {
        let changes = waveformSource != nil && waveformSource != source
        waveformSource = source
        guard changes, window != nil, !MotionPreference.reducesMotion else { return draw() }
        #if DEBUG
        debugWaveformTransitions += 1
        #endif
        UIView.transition(with: waveform, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction], animations: draw)
    }

    /// While it records: the holding row's dot, or the chip's.
    private func blink(_ on: Bool) {
        let target: CALayer? = mode == .recording ? dot.layer : chip.imageView?.layer
        for layer in [dot.layer, chip.imageView?.layer].compactMap({ $0 }) { layer.removeAnimation(forKey: "blink") }
        guard on, let target, !MotionPreference.reducesMotion else { return }
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1
        blink.toValue = 0.25
        blink.duration = 0.6
        blink.autoreverses = true
        blink.repeatCount = .infinity
        target.add(blink, forKey: "blink")
    }

    #if DEBUG
    var debugTimerText: String? { box.isHidden ? timerLabel.text : chip.configuration?.title }
    /// What VoiceOver reads for the time (#2294).
    var debugTimerAccessibilityLabel: String? { timerLabel.accessibilityLabel }
    /// The time is red: its last ten seconds.
    var debugTimerIsRunningOut: Bool { timerLabel.textColor == Palette.tint }
    var debugVisibleControls: [String] {
        var shown = [takeButton, sendButton].filter { !$0.isHidden }.compactMap(\.accessibilityLabel)
        if !box.isHidden, chip.isAccessibilityElement, let label = chip.accessibilityLabel { shown.insert(label, at: 0) }
        return shown
    }
    var debugShowsWaveform: Bool { !box.isHidden }
    var debugTimerFrame: CGRect { timerLabel.isHidden ? .zero : timerLabel.convert(timerLabel.bounds, to: self) }
    var debugHidesTimer: Bool { timerLabel.isHidden }
    var debugChipFrame: CGRect { chip.convert(chip.bounds, to: self) }
    var debugWaveformFrame: CGRect { waveform.convert(waveform.bounds, to: self) }
    var debugTakeFrame: CGRect { takeButton.convert(takeButton.bounds, to: self) }
    /// The take button's and the chip's faces, by name, and their images
    /// (the owner's play and pause, #2276).
    var debugTakeFace: String { shownTakeFace }
    var debugChipFace: String { shownChipFace }
    var debugTakeImage: UIImage? { takeButton.configuration?.image }
    var debugChipImage: UIImage? { chip.configuration?.image }
    /// How many times the row sprang: a change of faces alone never does.
    private(set) var debugSpringCount = 0
    /// How many times the bars cross-dissolved to another source.
    private(set) var debugWaveformTransitions = 0
    var debugSendFrame: CGRect { sendButton.convert(sendButton.bounds, to: self) }
    func debugTap(_ label: String) {
        if chip.accessibilityLabel == label { return chip.sendActions(for: .primaryActionTriggered) }
        [takeButton, sendButton]
            .first { $0.accessibilityLabel == label }?.sendActions(for: .primaryActionTriggered)
    }
    #endif
}

/// The lock above the mic while it holds (#2102): a glass capsule with a
/// padlock and a chevron, filling as the finger slides up.
final class VoiceLockCapsule: UIVisualEffectView {
    static let size = CGSize(width: 40, height: 84)
    private let fill = UIView()
    private let padlock = UIImageView(image: UIImage(systemName: "lock.open.fill"))
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.up"))

    init() {
        super.init(effect: UIGlassEffect())
        frame = CGRect(origin: .zero, size: Self.size)
        isUserInteractionEnabled = false
        cornerConfiguration = .capsule()
        clipsToBounds = true
        fill.backgroundColor = Palette.tint.withAlphaComponent(0.25)
        contentView.addSubview(fill)
        // ⚠️ A SQUARE THE SYMBOL CENTRES IN (the owner, 2026-11-07): sized
        // to the open padlock, the closed one — narrower — was stretched
        // into its frame and looked squashed.
        for (view, y) in [(padlock, 24.0), (chevron, 56.0)] as [(UIImageView, CGFloat)] {
            view.tintColor = .label
            view.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            view.contentMode = .center
            view.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
            view.center = CGPoint(x: Self.size.width / 2, y: y)
            contentView.addSubview(view)
        }
        setProgress(0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setProgress(_ progress: CGFloat) {
        let height = Self.size.height * progress
        fill.frame = CGRect(x: 0, y: Self.size.height - height, width: Self.size.width, height: height)
        chevron.alpha = 1 - progress
    }

    /// Open to closed: the symbol's own Replace.
    func close() {
        padlock.setSymbolImage(UIImage(systemName: "lock.fill")!, contentTransition: .replace)
    }
}
