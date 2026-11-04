import DesignSystem
import UIKit

/// The field's place while a voice message is recorded (#2102):
///
/// ```
/// recording   ● 0:07   ‹ Slide to cancel
/// locked      (🗑)  ● 0:42  ▁▂▅▇▅▃▂▁▃▆▇   (❚❚)  (↑)
/// paused      (🗑)  (▶︎)  ▂▅▇▅▃▂▅▇▆▃  0:42  (🎙)  (↑)
/// ```
final class VoiceRecordingStrip: UIView {
    enum Mode: Equatable {
        case recording
        case locked
        case paused(resumable: Bool, playing: Bool)
    }

    var onDelete: (() -> Void)?
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?
    var onPlay: (() -> Void)?
    var onSend: (() -> Void)?
    var onSeek: ((Double) -> Void)?

    private(set) var mode: Mode = .recording
    private let dot = UIView()
    private let timerLabel = UILabel()
    private let slideLabel = UILabel()
    let waveform = WaveformBars()
    private let deleteButton = VoiceRecordingStrip.button("trash", label: "Delete recording")
    private let pauseButton = VoiceRecordingStrip.button("pause.fill", label: "Pause recording")
    private let resumeButton = VoiceRecordingStrip.button("mic.fill", label: "Resume recording")
    private let playButton = VoiceRecordingStrip.button("play.fill", label: "Play recording")
    private let sendButton = VoiceRecordingStrip.button("arrow.up.circle.fill", label: "Send voice message")
    private let stack = UIStackView()
    private var liveLevels: [UInt8] = []

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
        waveform.heightAnchor.constraint(equalToConstant: 24).isActive = true
        waveform.onSeek = { [weak self] fraction, _ in self?.onSeek?(fraction) }

        deleteButton.addAction(UIAction { [weak self] _ in self?.onDelete?() }, for: .primaryActionTriggered)
        pauseButton.addAction(UIAction { [weak self] _ in self?.onPause?() }, for: .primaryActionTriggered)
        resumeButton.addAction(UIAction { [weak self] _ in self?.onResume?() }, for: .primaryActionTriggered)
        playButton.addAction(UIAction { [weak self] _ in self?.onPlay?() }, for: .primaryActionTriggered)
        sendButton.addAction(UIAction { [weak self] _ in self?.onSend?() }, for: .primaryActionTriggered)

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = Spacing.sm
        for part in [deleteButton, playButton, dot, timerLabel, slideLabel, waveform, pauseButton, resumeButton, sendButton] as [UIView] {
            stack.addArrangedSubview(part)
        }
        stack.setCustomSpacing(Spacing.xs, after: dot)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        apply(.recording)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func button(_ symbol: String, label: String) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        configuration.baseForegroundColor = .label
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label
        return button
    }

    func apply(_ mode: Mode) {
        self.mode = mode
        let recording = mode == .recording
        let locked = mode == .locked
        let paused: Bool, resumable: Bool, playing: Bool
        if case .paused(let canResume, let isPlaying) = mode {
            paused = true; resumable = canResume; playing = isPlaying
        } else {
            paused = false; resumable = false; playing = false
        }
        slideLabel.isHidden = !recording
        dot.isHidden = paused
        deleteButton.isHidden = recording
        pauseButton.isHidden = !locked
        resumeButton.isHidden = !(paused && resumable)
        playButton.isHidden = !paused
        playButton.configuration?.image = UIImage(systemName: playing ? "pause.fill" : "play.fill")
        playButton.accessibilityLabel = playing ? "Pause playback" : "Play recording"
        sendButton.isHidden = recording
        waveform.isHidden = recording
        if recording || locked { blink(true) } else { blink(false) }
    }

    /// The take's time; red in its last ten seconds, counting down (#2102).
    func setTime(_ seconds: TimeInterval, remaining: TimeInterval?) {
        if let remaining, remaining <= 10 {
            timerLabel.text = "-" + ThreadVoiceView.clock(remaining.rounded(.up))
            timerLabel.textColor = Palette.tint
        } else {
            timerLabel.text = ThreadVoiceView.clock(seconds)
            timerLabel.textColor = .label
        }
        timerLabel.accessibilityLabel = "\(Int(seconds)) seconds"
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
        waveform.configure(levels: Array(repeating: 0, count: max(0, count - shown.count)) + shown, barCount: count, progress: 0)
    }

    /// The paused bar's whole take, `progress` of it played back.
    func showTake(levels: [UInt8], duration: TimeInterval, progress: Double) {
        let count = ThreadVoiceView.barCount(forWidth: max(1, waveform.bounds.width))
        waveform.configure(levels: levels, barCount: count, progress: progress)
        setTime(progress > 0 ? duration * progress : duration, remaining: nil)
    }

    private func blink(_ on: Bool) {
        dot.layer.removeAnimation(forKey: "blink")
        guard on, !MotionPreference.reducesMotion else { return }
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1
        blink.toValue = 0.25
        blink.duration = 0.6
        blink.autoreverses = true
        blink.repeatCount = .infinity
        dot.layer.add(blink, forKey: "blink")
    }

    #if DEBUG
    var debugTimerText: String? { timerLabel.text }
    var debugVisibleControls: [String] {
        [deleteButton, playButton, pauseButton, resumeButton, sendButton].filter { !$0.isHidden }.compactMap(\.accessibilityLabel)
    }
    func debugTap(_ label: String) {
        [deleteButton, playButton, pauseButton, resumeButton, sendButton]
            .first { $0.accessibilityLabel == label }?.sendActions(for: .primaryActionTriggered)
    }
    #endif
}

/// The mic under the finger while it holds (#2102): a raspberry disc that
/// breathes with the voice — it is listening, without a meter.
final class VoiceMicDisc: UIView {
    static let side: CGFloat = 76
    private let breath = UIView()
    private let disc = UIView()
    private let glyph = UIImageView(image: UIImage(systemName: "mic.fill"))

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        isUserInteractionEnabled = false
        for view in [breath, disc] {
            view.frame = bounds
            view.layer.cornerRadius = Self.side / 2
            view.backgroundColor = Palette.tint
            addSubview(view)
        }
        breath.alpha = 0.25
        glyph.tintColor = .white
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        glyph.sizeToFit()
        glyph.center = CGPoint(x: bounds.midX, y: bounds.midY)
        addSubview(glyph)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The live level, 0…1: the soft ring swells with it.
    func setLevel(_ level: Float) {
        guard !MotionPreference.reducesMotion else { return }
        let scale = 1 + CGFloat(min(1, level * 2)) * 0.5
        UIView.animate(withDuration: 0.1, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.breath.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
    }

    /// The cancel's small scene: the mic gives way to a bin that drops away.
    func throwAway(completion: @escaping () -> Void) {
        guard window != nil, !MotionPreference.reducesMotion else {
            completion()
            return
        }
        glyph.image = UIImage(systemName: "trash.fill")
        UIView.animate(withDuration: 0.18, animations: {
            self.disc.backgroundColor = .systemRed
            self.breath.alpha = 0
        }) { _ in
            UIView.animate(withDuration: 0.32, delay: 0.12, options: [.curveEaseIn]) {
                self.transform = CGAffineTransform(translationX: 0, y: 60).scaledBy(x: 0.3, y: 0.3)
                self.alpha = 0
            } completion: { _ in completion() }
        }
    }
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
        for (view, y) in [(padlock, 24.0), (chevron, 56.0)] as [(UIImageView, CGFloat)] {
            view.tintColor = .label
            view.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            view.sizeToFit()
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

    func close() {
        padlock.image = UIImage(systemName: "lock.fill")
    }
}
