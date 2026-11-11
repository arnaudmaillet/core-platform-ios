import DesignSystem
import UIKit

/// The voice component's smallest size (#2205): a mic, a small still
/// waveform and the length — on grid tiles, the profile mosaic and map pins,
/// where a voice post keeps its text face and only the caption's place says
/// it speaks.
///
/// ```
///   🎙 ▂▅▇▅▃▂▅▇▆▃  32″
/// ```
///
/// - **Not interactive:** a tap is the tile's (it opens the post).
/// - **Read as part of its tile:** not an accessibility element of its own;
///   the tile reads `accessibilityDescription`.
/// - **Its ink is its ground's** (`ink`), set by the host.
public final class VoiceMarkView: UIView {
    /// The bars' height and count.
    public static let waveformHeight: CGFloat = 12
    public static let barCount = 12
    /// The mark is only ever a voice post's: its length in seconds, "32″"
    /// (#2294).
    public static let timerStyle = VoiceView.TimerStyle(role: .post(author: nil))

    private let mic = UIImageView()
    private let waveform = WaveformBars()
    private let durationLabel = UILabel()
    private let stack = UIStackView()
    private(set) var duration: TimeInterval = 0

    public var ink: UIColor = VoiceView.ink {
        didSet { applyInk() }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        mic.image = UIImage(systemName: "mic.fill")
        mic.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption2, scale: .small)
        mic.setContentHuggingPriority(.required, for: .horizontal)
        waveform.scrubs = false
        waveform.isUserInteractionEnabled = false
        waveform.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.font = .scaledMonospacedDigitSystemFont(
            ofSize: UIFont.defaultPointSize(for: .caption2), relativeTo: .caption2
        )
        durationLabel.adjustsFontForContentSizeCategory = true
        durationLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = Spacing.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        for part in [mic, waveform, durationLabel] as [UIView] { stack.addArrangedSubview(part) }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            waveform.heightAnchor.constraint(equalToConstant: Self.waveformHeight),
        ])
        applyInk()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The post's voice: its length and its levels (100, 0–31), or nil for
    /// the generic shape when the summary carries none.
    public func configure(duration: TimeInterval, levels: [UInt8]?) {
        self.duration = duration
        waveform.configure(levels: levels ?? VoiceView.genericLevels, barCount: Self.barCount, progress: 0)
        // A voice post's length, in its seconds (#2294).
        durationLabel.text = VoiceView.timerText(duration, style: Self.timerStyle)
        invalidateIntrinsicContentSize()
    }

    /// What its tile reads (#2205): "Voice post, 32 seconds".
    public var accessibilityDescription: String {
        VoiceView.accessibilityLabel(role: .post(author: nil), senderName: nil, duration: duration, unplayed: false)
    }

    private func applyInk() {
        mic.tintColor = ink
        durationLabel.textColor = ink
        // Still: every bar is "unplayed", in the ground's ink.
        waveform.unplayedInk = ink.withAlphaComponent(0.75)
        waveform.playedInk = ink
    }

    #if DEBUG
    public var debugDurationText: String? { durationLabel.text }
    public var debugBarCount: Int { waveform.bars.count }
    #endif
}
