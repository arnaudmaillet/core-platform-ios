import DesignSystem
import FeedInterface
import UIKit

/// A voice message in the conversation (#2104), under its row as a photo is
/// (`ThreadMediaView`), indented to the text column:
///
/// ```
///  (▶︎)  ▂▅▇▅▃▂▅▇▆▃▂▁▃▅▇▅▃▂▁▂▃   0:12  •
///  play   waveform (played | unplayed)  timer unplayed dot
/// ```
///
/// - **Its width says its length:** 140 pt at 1 s to 240 pt from 30 s.
/// - **The waveform is the message's face:** 2 pt bars, the played ones in
///   the brand's raspberry, re-binned from the message's 100 levels.
/// - **The speed chip takes the timer's place** while it plays or is paused
///   mid-way (WhatsApp's): the row never grows.
/// - **It draws; the screen plays** (`VoicePlayer`, one for the app): every
///   tap is told through the callbacks.
final class ThreadVoiceView: UIView {
    /// What the bubble shows, all of it — so a reused cell never keeps
    /// another message's progress.
    struct State: Equatable {
        var delivery: ConversationThreadDelivery = .sent
        var levels: [UInt8]? = nil
        var duration: TimeInterval = 0
        /// A received message the viewer hasn't played.
        var unplayed = false
        var playback: Playback = .rest
        var speedLabel = "1×"

        enum Playback: Equatable {
            /// Not started, or played to its end: the duration shows.
            case rest
            case loading
            case playing(progress: Double)
            /// Paused mid-way.
            case paused(progress: Double)
            /// The audio could not be read: ↻.
            case failed
        }

        var progress: Double {
            switch playback {
            case .playing(let progress), .paused(let progress): progress
            default: 0
            }
        }

        var isUnderway: Bool {
            switch playback {
            case .playing, .paused: true
            default: false
            }
        }
    }

    // MARK: - Geometry

    static let minWidth: CGFloat = 140
    static let maxWidth: CGFloat = 240
    static let discSide: CGFloat = 36
    static let barWidth: CGFloat = 2
    static let barGap: CGFloat = 2
    static let minBarHeight: CGFloat = 2
    static let waveformHeight: CGFloat = 28

    /// The bubble's width for a length: 140 pt at 1 s, 240 pt from 30 s,
    /// straight between — length reads at a glance.
    static func width(forDuration duration: TimeInterval) -> CGFloat {
        let progress = min(1, max(0, (duration - 1) / 29))
        return (minWidth + (maxWidth - minWidth) * progress).rounded()
    }

    /// How many bars a waveform `width` wide holds: 2 pt bars, 2 pt apart
    /// (about 45 at 180 pt).
    static func barCount(forWidth width: CGFloat) -> Int {
        max(1, Int((width + barGap) / (barWidth + barGap)))
    }

    /// The message's levels as `count` bars: the loudest level of each bin.
    static func rebin(_ levels: [UInt8], to count: Int) -> [UInt8] {
        guard count > 0 else { return [] }
        guard !levels.isEmpty else { return Array(repeating: 0, count: count) }
        let n = levels.count
        return (0..<count).map { bar in
            let start = bar * n / count
            let end = max(start + 1, (bar + 1) * n / count)
            return levels[start..<min(end, n)].max() ?? 0
        }
    }

    /// A length as the timer shows it: "0:12", "12:04", "1:02:03".
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        let hours = whole / 3_600, minutes = whole % 3_600 / 60, rest = whole % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    // MARK: - Callbacks

    /// Play or pause (or try again after a failure).
    var onPlayTap: (() -> Void)?
    /// A tap or a drag on the waveform, 0…1; `scrubbing` while the finger is down.
    var onSeek: ((_ fraction: Double, _ scrubbing: Bool) -> Void)?
    var onSpeedTap: (() -> Void)?
    /// "Not sent. Tap to retry".
    var onRetry: (() -> Void)?

    // MARK: - Parts

    private let frameView = UIView()
    private let playButton = UIButton(configuration: .glass())
    private let glyph = UIImageView()
    private let loader = AppLoaderView(size: .medium)
    let waveform = WaveformBars()
    private let timerLabel = UILabel()
    private let speedChip = UIButton(configuration: .gray())
    private let dot = UIView()
    private let failedLabel = UILabel()
    private var widthConstraint: NSLayoutConstraint?
    private(set) var state = State()
    private var shownGlyph = ""
    private var scrubSteps = -1

    init() {
        super.init(frame: .zero)
        frameView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(frameView)

        playButton.configuration?.cornerStyle = .capsule
        playButton.isAccessibilityElement = false
        playButton.addAction(UIAction { [weak self] _ in self?.onPlayTap?() }, for: .primaryActionTriggered)
        glyph.tintColor = .label
        glyph.contentMode = .center
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        glyph.isUserInteractionEnabled = false
        loader.isHidden = true

        timerLabel.font = .scaledMonospacedDigitSystemFont(
            ofSize: UIFont.defaultPointSize(for: .caption1), relativeTo: .caption1
        )
        timerLabel.adjustsFontForContentSizeCategory = true
        timerLabel.textColor = .secondaryLabel
        timerLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        speedChip.configuration?.cornerStyle = .capsule
        speedChip.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)
        speedChip.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .scaledFont(forTextStyle: .caption1, weight: .semibold)
            return attributes
        }
        speedChip.isAccessibilityElement = false
        speedChip.isHidden = true
        speedChip.addAction(UIAction { [weak self] _ in
            self?.popChip()
            self?.onSpeedTap?()
        }, for: .primaryActionTriggered)

        dot.backgroundColor = Palette.tint
        dot.layer.cornerRadius = 3
        dot.isHidden = true

        failedLabel.text = "Not sent. Tap to retry"
        failedLabel.font = .appFont(forTextStyle: .caption1)
        failedLabel.adjustsFontForContentSizeCategory = true
        failedLabel.textColor = .systemRed
        failedLabel.isHidden = true
        failedLabel.isUserInteractionEnabled = true
        failedLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(retryTapped)))

        waveform.onSeek = { [weak self] fraction, scrubbing in self?.seek(fraction, scrubbing: scrubbing) }

        for part in [playButton, glyph, loader, waveform, timerLabel, speedChip, dot, failedLabel] as [UIView] {
            part.translatesAutoresizingMaskIntoConstraints = false
        }
        frameView.addSubview(playButton)
        playButton.addSubview(glyph)
        playButton.addSubview(loader)
        frameView.addSubview(waveform)
        frameView.addSubview(timerLabel)
        frameView.addSubview(speedChip)
        frameView.addSubview(dot)
        frameView.addSubview(failedLabel)

        let width = frameView.widthAnchor.constraint(equalToConstant: Self.maxWidth)
        width.priority = .required - 1
        widthConstraint = width
        NSLayoutConstraint.activate([
            frameView.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: CommentRowView.avatarSize + CommentRowView.avatarGap
            ),
            frameView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            frameView.topAnchor.constraint(equalTo: topAnchor),
            frameView.bottomAnchor.constraint(equalTo: bottomAnchor),
            width,

            playButton.leadingAnchor.constraint(equalTo: frameView.leadingAnchor),
            playButton.topAnchor.constraint(equalTo: frameView.topAnchor),
            playButton.widthAnchor.constraint(equalToConstant: Self.discSide),
            playButton.heightAnchor.constraint(equalToConstant: Self.discSide),
            glyph.centerXAnchor.constraint(equalTo: playButton.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            loader.centerXAnchor.constraint(equalTo: playButton.centerXAnchor),
            loader.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),

            waveform.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: Spacing.sm),
            waveform.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            waveform.heightAnchor.constraint(equalToConstant: Self.waveformHeight),

            timerLabel.leadingAnchor.constraint(equalTo: waveform.trailingAnchor, constant: Spacing.sm),
            timerLabel.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            speedChip.leadingAnchor.constraint(equalTo: timerLabel.leadingAnchor),
            speedChip.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            dot.leadingAnchor.constraint(equalTo: timerLabel.trailingAnchor, constant: Spacing.xs),
            dot.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            dot.trailingAnchor.constraint(equalTo: frameView.trailingAnchor),

            failedLabel.leadingAnchor.constraint(equalTo: frameView.leadingAnchor),
            failedLabel.topAnchor.constraint(equalTo: playButton.bottomAnchor, constant: Spacing.xs),
        ])
        let bottom = playButton.bottomAnchor.constraint(equalTo: frameView.bottomAnchor)
        bottom.priority = .defaultHigh
        bottom.isActive = true
        failedBottom = failedLabel.bottomAnchor.constraint(equalTo: frameView.bottomAnchor)

        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var failedBottom: NSLayoutConstraint?
    /// Who sent it, for VoiceOver: "Ava", or nil for the viewer's own.
    private var senderName: String?

    // MARK: - Showing

    /// Shows `state` — nil hides the bubble (a message that is not a voice
    /// message). Nothing of a previous message survives.
    func configure(_ state: State?, senderName: String? = nil) {
        guard let state else {
            isHidden = true
            self.state = State()
            waveform.configure(levels: nil, barCount: 0, progress: 0)
            return
        }
        isHidden = false
        self.senderName = senderName
        let width = Self.width(forDuration: state.duration)
        widthConstraint?.constant = width
        let waveformWidth = width - Self.discSide - 2 * Spacing.sm - 34 - Spacing.xs - 6
        waveform.configure(
            levels: state.levels, barCount: Self.barCount(forWidth: waveformWidth), progress: state.progress
        )
        apply(state)
    }

    /// Updates what changes while it plays — progress, the glyph, the chip —
    /// without re-laying the bars.
    func update(_ state: State) {
        guard !isHidden else { return }
        waveform.setProgress(state.progress)
        apply(state)
    }

    private func apply(_ state: State) {
        let previous = self.state
        self.state = state
        let sending = state.delivery == .sending
        let failedSend = state.delivery == .failed
        frameView.alpha = sending ? 0.5 : 1
        failedLabel.isHidden = !failedSend
        failedBottom?.isActive = failedSend

        let loading = sending || state.playback == .loading
        loader.isHidden = !loading
        if loading { loader.startAnimating() } else { loader.stopAnimating() }
        glyph.isHidden = loading
        setGlyph(
            state.playback == .failed ? "arrow.clockwise"
                : { if case .playing = state.playback { "pause.fill" } else { "play.fill" } }()
        )
        playButton.isEnabled = !sending && !failedSend

        timerLabel.text = state.isUnderway
            ? Self.clock(state.duration * state.progress)
            : Self.clock(state.duration)
        // The chip in the timer's place while it plays or is paused mid-way.
        speedChip.isHidden = !state.isUnderway
        timerLabel.alpha = state.isUnderway ? 0 : 1
        speedChip.configuration?.title = state.speedLabel

        // The unplayed dot fades once playback starts.
        let showsDot = state.unplayed && !state.isUnderway && state.playback != .loading
        if showsDot != !dot.isHidden {
            if showsDot || window == nil || MotionPreference.reducesMotion {
                dot.isHidden = !showsDot
                dot.alpha = 1
            } else {
                UIView.animate(withDuration: AppearMotion.fadeDuration, animations: { self.dot.alpha = 0 }) { _ in
                    self.dot.isHidden = true
                    self.dot.alpha = 1
                }
            }
        }
        if previous.levels == nil, state.levels != nil, window != nil { waveform.riseIn() }
        updateAccessibility()
    }

    private func setGlyph(_ name: String) {
        guard name != shownGlyph else { return }
        let animated = window != nil && !shownGlyph.isEmpty && !MotionPreference.reducesMotion
        shownGlyph = name
        glyph.image = UIImage(systemName: name)
        guard animated else { return }
        // The sound sheet's swap, not the system's replace: a bounce up from
        // small as it fades in, drawn in the glass like any view.
        glyph.alpha = 0
        glyph.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        UIView.animate(
            withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0,
            options: [.allowUserInteraction]
        ) {
            self.glyph.alpha = 1
            self.glyph.transform = .identity
        }
    }

    private func popChip() {
        guard window != nil, !MotionPreference.reducesMotion else { return }
        speedChip.transform = CGAffineTransform(scaleX: 1.18, y: 1.18)
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0) {
            self.speedChip.transform = .identity
        }
    }

    // MARK: - Scrubbing

    private func seek(_ fraction: Double, scrubbing: Bool) {
        guard state.delivery == .sent else { return }
        // A tick every 10 %, under the finger.
        let step = Int(fraction * 10)
        if scrubbing, step != scrubSteps {
            if scrubSteps >= 0 { Haptics.play(.tick) }
            scrubSteps = step
        }
        if !scrubbing { scrubSteps = -1 }
        onSeek?(fraction, scrubbing)
    }

    @objc private func retryTapped() { onRetry?() }

    // MARK: - Accessibility

    private func updateAccessibility() {
        let seconds = Int(state.duration.rounded())
        let length = seconds == 1 ? "1 second" : "\(seconds) seconds"
        let from = senderName.map { "Voice message from \($0)" } ?? "Your voice message"
        let heard = state.unplayed ? "not played" : "played"
        accessibilityLabel = "\(from), \(length), \(heard)"
        accessibilityValue = state.isUnderway ? Self.clock(state.duration * state.progress) : nil
        let playing: Bool = if case .playing = state.playback { true } else { false }
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: playing ? "Pause" : "Play") { [weak self] _ in
                self?.onPlayTap?()
                return true
            },
            UIAccessibilityCustomAction(name: "Speed \(state.speedLabel)") { [weak self] _ in
                self?.onSpeedTap?()
                return true
            },
        ]
    }

    /// ±5 s.
    override func accessibilityIncrement() { nudge(by: 5) }
    override func accessibilityDecrement() { nudge(by: -5) }

    private func nudge(by seconds: TimeInterval) {
        guard state.duration > 0 else { return }
        let fraction = min(1, max(0, state.progress + seconds / state.duration))
        onSeek?(fraction, false)
    }

    #if DEBUG
    var debugTimerText: String? { timerLabel.text }
    var debugShowsChip: Bool { !speedChip.isHidden }
    var debugChipTitle: String? { speedChip.configuration?.title }
    var debugShowsDot: Bool { !dot.isHidden }
    var debugShowsLoader: Bool { !loader.isHidden }
    var debugGlyph: String { shownGlyph }
    var debugWidth: CGFloat { widthConstraint?.constant ?? 0 }
    func debugTapPlay() { onPlayTap?() }
    func debugTapSpeed() { onSpeedTap?() }
    #endif
}

/// The voice message's waveform: 2 pt round-capped bars, the played ones in
/// the brand's raspberry. A tap seeks; a horizontal drag scrubs (a vertical
/// one is the list's, and a long press stays the row's menu).
final class WaveformBars: UIView, UIGestureRecognizerDelegate {
    var onSeek: ((_ fraction: Double, _ scrubbing: Bool) -> Void)?

    private(set) var bars: [UInt8] = []
    private(set) var progress: Double = 0
    private var waiting = true
    private let playhead = UIView()
    private var rise: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
        playhead.backgroundColor = Palette.tint
        playhead.isHidden = true
        addSubview(playhead)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(levels: [UInt8]?, barCount: Int, progress: Double) {
        waiting = levels == nil
        // Waiting for a waveform: a flat row of minimum bars.
        bars = ThreadVoiceView.rebin(levels ?? [], to: barCount)
        self.progress = progress
        rise = 1
        setNeedsDisplay()
    }

    func setProgress(_ progress: Double) {
        guard abs(progress - self.progress) > 0.0005 else { return }
        self.progress = progress
        setNeedsDisplay()
    }

    /// The waveform arriving rises into place, once.
    func riseIn() {
        guard !MotionPreference.reducesMotion else { return }
        rise = 0
        let start = CACurrentMediaTime()
        let link = CADisplayLink(target: RiseStep { [weak self] link in
            guard let self else { return link.invalidate() }
            let t = min(1, (CACurrentMediaTime() - start) / 0.3)
            rise = CGFloat(1 - pow(1 - t, 3))
            setNeedsDisplay()
            if t >= 1 { link.invalidate() }
        }, selector: #selector(RiseStep.fire(_:)))
        link.add(to: .main, forMode: .common)
    }

    override func draw(_ rect: CGRect) {
        guard !bars.isEmpty else { return }
        let step = ThreadVoiceView.barWidth + ThreadVoiceView.barGap
        let played = Int((progress * Double(bars.count)).rounded(.down))
        for (index, level) in bars.enumerated() {
            let full = waiting ? 0 : CGFloat(level) / 31 * bounds.height * rise
            let height = max(ThreadVoiceView.minBarHeight, full)
            let bar = CGRect(
                x: CGFloat(index) * step, y: (bounds.height - height) / 2,
                width: ThreadVoiceView.barWidth, height: height
            )
            (index < played ? Palette.tint : UIColor.tertiaryLabel).setFill()
            UIBezierPath(roundedRect: bar, cornerRadius: ThreadVoiceView.barWidth / 2).fill()
        }
    }

    // MARK: - Seeking

    private func fraction(at point: CGPoint) -> Double {
        let used = CGFloat(bars.count) * (ThreadVoiceView.barWidth + ThreadVoiceView.barGap)
        return Double(min(1, max(0, point.x / max(1, min(used, bounds.width)))))
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        onSeek?(fraction(at: tap.location(in: self)), false)
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let fraction = fraction(at: pan.location(in: self))
        switch pan.state {
        case .began, .changed:
            playhead.isHidden = false
            playhead.frame = CGRect(x: CGFloat(fraction) * bounds.width - 1, y: 0, width: 2, height: bounds.height)
            onSeek?(fraction, true)
        default:
            playhead.isHidden = true
            onSeek?(fraction, false)
        }
    }

    /// Only a horizontal drag scrubs.
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y)
    }

    private final class RiseStep: NSObject {
        let action: (CADisplayLink) -> Void
        init(_ action: @escaping (CADisplayLink) -> Void) { self.action = action }
        @objc func fire(_ link: CADisplayLink) { action(link) }
    }

    #if DEBUG
    var debugWaiting: Bool { waiting }
    #endif
}
