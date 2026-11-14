#if DEBUG
import LaunchArguments
import UIKit

/// `-voice-lab`: the voice engine on a bench (#2101), alone in the window —
/// record, pause, resume, finish, cancel; the live level; the 1 s rule; the
/// waveform as plain bars; playback at each speed, and seek. No design: the
/// composer (#2102) and the row (#2104) draw the real thing.
@MainActor
public enum VoiceLab {
    public static var isRequested: Bool { LaunchArgument.voiceLab.isPassed() }

    public static func makeRoot() -> UIViewController { UINavigationController(rootViewController: VoiceLabViewController()) }
}

@MainActor
final class VoiceLabViewController: UIViewController {
    private let recorder = VoiceRecorder()
    private let player = VoicePlayer.shared
    private var draft: VoiceDraft?

    private let stateLabel = UILabel()
    private let levelBar = UIProgressView(progressViewStyle: .default)
    private let waveformView = WaveformBarsView()
    private let speedControl = UISegmentedControl(items: VoicePlaybackSpeed.allCases.map(\.label))
    private let seekSlider = UISlider()
    private let playButton = UIButton(configuration: .filled())
    private var buttons: [String: UIButton] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Voice lab"
        view.backgroundColor = .systemBackground
        stateLabel.numberOfLines = 0
        stateLabel.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        speedControl.selectedSegmentIndex = VoicePlaybackSpeed.allCases.firstIndex(of: player.speed) ?? 0
        speedControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            player.setSpeed(VoicePlaybackSpeed.allCases[speedControl.selectedSegmentIndex])
        }, for: .valueChanged)
        seekSlider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            player.seek(to: Double(seekSlider.value))
        }, for: .valueChanged)
        playButton.configuration?.title = "Play"
        playButton.addAction(UIAction { [weak self] _ in self?.togglePlay() }, for: .primaryActionTriggered)
        waveformView.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let take = UIStackView(arrangedSubviews: [
            button("Record") { [weak self] in await self?.record() },
            button("Pause") { [weak self] in self?.recorder.pause() },
            button("Resume") { [weak self] in self?.recorder.resume() },
        ])
        take.distribution = .fillEqually
        take.spacing = 8
        let end = UIStackView(arrangedSubviews: [
            button("Finish") { [weak self] in self?.finish() },
            button("Cancel") { [weak self] in self?.recorder.cancel(); self?.recorder.reset() },
        ])
        end.distribution = .fillEqually
        end.spacing = 8

        let stack = UIStackView(arrangedSubviews: [
            stateLabel, levelBar, take, end, waveformView, playButton, speedControl, seekSlider,
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])

        recorder.onStateChange = { [weak self] _ in self?.render() }
        recorder.onLevel = { [weak self] level in
            self?.levelBar.progress = level
            self?.render()
        }
        recorder.onTimeRunningOut = { [weak self] in self?.note("10 s left") }
        recorder.onAutoFinish = { [weak self] outcome in self?.landed(outcome, auto: true) }
        player.onChange = { [weak self] in self?.render() }
        render()
    }

    private var lastNote = ""

    private func note(_ text: String) {
        lastNote = text
        render()
    }

    private func button(_ title: String, _ action: @escaping @MainActor () async -> Void) -> UIButton {
        let button = UIButton(configuration: .gray())
        button.configuration?.title = title
        button.addAction(UIAction { _ in Task { @MainActor in await action() } }, for: .primaryActionTriggered)
        buttons[title] = button
        return button
    }

    private func record() async {
        if case .finished = recorder.state { recorder.reset() }
        if recorder.state == .cancelled { recorder.reset() }
        switch await recorder.start() {
        case .started: note("recording")
        case .askedPermission(let granted): note(granted ? "permission granted: record again" : "permission refused")
        case .denied: note("microphone denied: Settings")
        case .failed: note("could not record")
        }
    }

    private func finish() {
        guard let outcome = recorder.finish() else { return }
        landed(outcome, auto: false)
    }

    private func landed(_ outcome: VoiceRecorder.FinishOutcome, auto: Bool) {
        switch outcome {
        case .tooShort:
            note("too short (under 1 s)\(auto ? ", auto" : "")")
        case .draft(let draft):
            self.draft = draft
            waveformView.levels = draft.waveform
            note(String(format: "draft %.1f s%@", draft.duration, auto ? ", auto-finished" : ""))
        }
    }

    private func togglePlay() {
        guard let draft else { return note("no draft yet") }
        player.toggle(draft.fileURL.lastPathComponent, url: draft.fileURL)
    }

    private func render() {
        let playerLine = String(format: "%@ %.1f/%.1f s", "\(player.state)", player.currentTime, player.duration ?? 0)
        stateLabel.text = """
        take: \(recorder.state.short) \(String(format: "%.1f s", recorder.elapsed))
        level: \(String(format: "%.2f", recorder.level))
        player: \(playerLine)
        \(lastNote)
        """
        playButton.configuration?.title = player.state == .playing ? "Pause" : "Play"
        if let progress = player.progress, !seekSlider.isTracking { seekSlider.value = Float(progress) }
        waveformView.progress = player.progress ?? 0
    }
}

private extension VoiceRecorder.State {
    var short: String {
        switch self {
        case .idle: "idle"
        case .recording: "recording"
        case .paused: "paused"
        case .finished: "finished"
        case .cancelled: "cancelled"
        }
    }
}

/// The waveform as plain bars, the played part tinted.
private final class WaveformBarsView: UIView {
    var levels: [UInt8] = [] { didSet { setNeedsDisplay() } }
    var progress: Double = 0 { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ rect: CGRect) {
        guard !levels.isEmpty else { return }
        let width = bounds.width / CGFloat(levels.count)
        for (index, level) in levels.enumerated() {
            let height = max(2, bounds.height * CGFloat(level) / CGFloat(VoiceWaveform.maxLevel))
            let bar = CGRect(x: CGFloat(index) * width, y: (bounds.height - height) / 2, width: max(1, width - 1), height: height)
            let played = Double(index) / Double(levels.count) < progress
            (played ? tintColor : UIColor.tertiaryLabel).setFill()
            UIBezierPath(rect: bar).fill()
        }
    }
}
#endif
