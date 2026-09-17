import DesignSystem
import MediaPlayback
import UIKit

/// What the band holds while the song tools are open on a video.
///
/// ```
///  (📁 Files) (🎞 From a video) 🗑        Song title
///  ▁▃▅▇▅▃▁▃ ┃▅▇█▇▅▃▁▃▅▇█▇▅▃┃ ▁▃▅▇▅▃▁     ← MediaWaveformExcerptView
///  ♪ ━━━━━●━━━━━━      🎞 ━━━━━━━●━━━     ← the song's level, the film's
/// ```
///
/// ⚠️ **ONE HEIGHT, SONG OR NOT.** Without a song the two lower rows give way to
/// a line saying where one can come from; the band does not jump when a song
/// arrives, and the picture above it does not move.
///
/// ⚠️ **A HOST THAT FORWARDS.** It knows nothing of edits or players: the
/// levels move live through `onLevels` and are stored through
/// `onLevelsSettled`, the start through the excerpt's own pair —
/// `MediaEditorSoundtrackMode` decides what each means.
///
/// ⚠️ **NO BACKGROUND** — the band's rule, inherited.
@MainActor
final class MediaSoundtrackToolsView: UIView {
    private enum Metrics {
        static let chip: CGFloat = 30
        static let chipPadding: CGFloat = 12
        static let sliders: CGFloat = 30
        static let symbol: CGFloat = 14
    }

    nonisolated static var height: CGFloat {
        Metrics.chip + Spacing.sm + MediaWaveformExcerptView.height + Spacing.sm + Metrics.sliders
    }

    /// What the empty tools say.
    static let emptyHint = "Pick a song from Files, or use the sound of another video."

    /// The SF Symbols this view draws.
    enum Symbol {
        static let files = "folder"
        static let video = "film"
        static let remove = "trash"
        static let song = "music.note"
        static let film = "speaker.wave.2"
    }

    /// Every symbol above — asked of the runtime in a test, since a name that
    /// is not a symbol draws nothing and still takes taps.
    static let symbols = [Symbol.files, Symbol.video, Symbol.remove, Symbol.song, Symbol.film]

    var onPick: ((MediaSoundtrackOrigin) -> Void)?
    var onRemove: (() -> Void)?
    /// A level moved under a finger: song, film.
    var onLevels: ((Double, Double) -> Void)?
    /// A level was let go of: song, film.
    var onLevelsSettled: ((Double, Double) -> Void)?
    /// The excerpt was let go of.
    var onStartSettled: ((Double) -> Void)?

    private lazy var files = makeChip(symbol: Symbol.files, title: "Files") { [weak self] in
        self?.onPick?(.files)
    }
    private lazy var video = makeChip(symbol: Symbol.video, title: "From a video") { [weak self] in
        self?.onPick?(.video)
    }
    private lazy var remove: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(
            systemName: Symbol.remove,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Metrics.symbol, weight: .semibold)
        )
        configuration.baseForegroundColor = .label
        configuration.contentInsets = .zero
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.onRemove?()
        })
        button.accessibilityLabel = "Remove the song"
        button.widthAnchor.constraint(equalToConstant: Metrics.chip).isActive = true
        return button
    }()

    private let title = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let message = UILabel()
    private let excerpt = MediaWaveformExcerptView()
    private let musicLevel = UISlider()
    private let filmLevel = UISlider()
    private lazy var levels: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [
            makeIcon(Symbol.song), musicLevel, makeIcon(Symbol.film), filmLevel
        ])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = Spacing.sm
        stack.setCustomSpacing(Spacing.lg, after: musicLevel)
        return stack
    }()

    private var hasSong = false
    private var problemClear: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear

        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabel
        title.textAlignment = .right
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spinner.hidesWhenStopped = true

        let row = UIStackView(arrangedSubviews: [files, video, remove, title, spinner])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Spacing.sm
        row.constrain(in: self) { view in
            row.topAnchor.constraint(equalTo: view.topAnchor)
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.lg)
            row.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Spacing.lg)
            row.heightAnchor.constraint(equalToConstant: Metrics.chip)
        }

        excerpt.onSettle = { [weak self] seconds in self?.onStartSettled?(seconds) }
        excerpt.constrain(in: self) { view in
            excerpt.topAnchor.constraint(equalTo: row.bottomAnchor, constant: Spacing.sm)
            excerpt.leadingAnchor.constraint(equalTo: view.leadingAnchor)
            excerpt.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        }

        for (slider, label) in [(musicLevel, "Song volume"), (filmLevel, "Original sound volume")] {
            slider.minimumValue = 0
            slider.maximumValue = 1
            slider.value = 1
            slider.accessibilityLabel = label
            slider.addAction(UIAction { [weak self] _ in self?.levelMoved() }, for: .valueChanged)
            slider.addAction(
                UIAction { [weak self] _ in self?.levelLetGo() },
                for: [.touchUpInside, .touchUpOutside, .touchCancel]
            )
        }
        levels.constrain(in: self) { view in
            levels.topAnchor.constraint(equalTo: excerpt.bottomAnchor, constant: Spacing.sm)
            levels.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.lg)
            levels.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Spacing.lg)
            levels.heightAnchor.constraint(equalToConstant: Metrics.sliders)
        }
        musicLevel.widthAnchor.constraint(equalTo: filmLevel.widthAnchor).isActive = true

        message.font = .systemFont(ofSize: 13)
        message.textColor = .secondaryLabel
        message.textAlignment = .center
        message.numberOfLines = 2
        message.constrain(in: self) { view in
            message.topAnchor.constraint(equalTo: row.bottomAnchor, constant: Spacing.sm)
            message.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            message.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.lg)
            message.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Spacing.lg)
        }

        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        show(song: nil, songSeconds: nil, filmSeconds: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - What it shows

    /// The page's song — nil for none — and the film it goes under.
    ///
    /// ⚠️ **STATES THE VALUES WITHOUT ANNOUNCING THEM**, for a page swiped to:
    /// nothing here calls back.
    func show(song: VideoSoundtrack?, songSeconds: Double?, filmSeconds: Double) {
        hasSong = song != nil
        title.text = song?.title
        title.accessibilityLabel = song.map { "Song: \($0.title)" }
        remove.isEnabled = hasSong
        if let song {
            excerpt.configure(
                songSeconds: songSeconds ?? song.startSeconds + filmSeconds,
                filmSeconds: filmSeconds, start: song.startSeconds
            )
            musicLevel.value = Float(song.musicVolume)
            filmLevel.value = Float(song.originalVolume)
        } else {
            excerpt.setPeaks([], bucketSeconds: AudioWaveform.bucketSeconds)
        }
        clearProblem()
    }

    /// The song's loudness, once it has been read.
    func show(peaks: [Float]) {
        excerpt.setPeaks(peaks, bucketSeconds: AudioWaveform.bucketSeconds)
    }

    /// Says what went wrong with a pick, in place of the song's controls, for a
    /// few seconds.
    func showProblem(_ text: String) {
        problemClear?.cancel()
        message.text = text
        layOutRows(problem: true)
        problemClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.clearProblem()
        }
    }

    /// While a pick is being copied and checked: the pickers cannot be opened
    /// again, and a spinner says why.
    func setBusy(_ busy: Bool) {
        files.isEnabled = !busy
        video.isEnabled = !busy
        remove.isEnabled = !busy && hasSong
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    private func clearProblem() {
        problemClear?.cancel()
        problemClear = nil
        message.text = Self.emptyHint
        layOutRows(problem: false)
    }

    private func layOutRows(problem: Bool) {
        let controls = hasSong && !problem
        excerpt.isHidden = !controls
        levels.isHidden = !controls
        message.isHidden = controls
    }

    // MARK: - The levels

    /// ⚠️ **TO A HUNDREDTH.** A slider holds a `Float`, and 0.3 read back as a
    /// `Double` is 0.30000001192092896 — a level nobody chose, stored as one.
    private var levelValues: (Double, Double) {
        func level(_ value: Float) -> Double { (Double(value) * 100).rounded() / 100 }
        return (level(musicLevel.value), level(filmLevel.value))
    }

    private func levelMoved() {
        let (music, film) = levelValues
        onLevels?(music, film)
        // ⚠️ VOICEOVER STEPS A SLIDER WITHOUT A TOUCH, so a change that no
        // finger is making is also the moment it is let go of.
        if !musicLevel.isTracking, !filmLevel.isTracking { levelLetGo() }
    }

    private func levelLetGo() {
        let (music, film) = levelValues
        onLevelsSettled?(music, film)
    }

    // MARK: - Parts

    private func makeIcon(_ symbol: String) -> UIImageView {
        let icon = UIImageView(image: UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Metrics.symbol, weight: .semibold)
        ))
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.isAccessibilityElement = false
        return icon
    }

    /// A capsule with a symbol and a word — the crop tools' shape chips, with
    /// an icon.
    private func makeChip(symbol: String, title: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Metrics.symbol - 1, weight: .semibold)
        )
        configuration.imagePadding = Spacing.xs
        var attributes = AttributeContainer()
        attributes.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        configuration.attributedTitle = AttributedString(title, attributes: attributes)
        configuration.baseForegroundColor = .label
        configuration.background.backgroundColor = UIColor.label.withAlphaComponent(0.12)
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 0, leading: Metrics.chipPadding, bottom: 0, trailing: Metrics.chipPadding
        )
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.heightAnchor.constraint(equalToConstant: Metrics.chip).isActive = true
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
}

extension MediaSoundtrackToolsView {
    /// Internal for tests: the excerpt, to drag without a finger.
    var debugExcerpt: MediaWaveformExcerptView { excerpt }
    /// Internal for tests: a tap on one of the two sources.
    func debugTapPick(_ origin: MediaSoundtrackOrigin) {
        (origin == .files ? files : video).sendActions(for: .touchUpInside)
    }
    /// Internal for tests: a tap on Remove.
    func debugTapRemove() { remove.sendActions(for: .touchUpInside) }
    var debugCanRemove: Bool { remove.isEnabled }
    var debugCanPick: Bool { files.isEnabled && video.isEnabled }
    /// Internal for tests: the name the row shows.
    var debugTitle: String? { title.text }
    /// Internal for tests: the line shown instead of the song's controls, or nil
    /// while they are showing.
    var debugMessage: String? { message.isHidden ? nil : message.text }
    /// Internal for tests: the two levels as drawn.
    var debugLevels: (music: Double, original: Double) { levelValues }
    /// Internal for tests: a finger dragging a level, then letting go.
    func debugDragLevels(music: Double, original: Double) {
        musicLevel.value = Float(music)
        filmLevel.value = Float(original)
        onLevels?(music, original)
    }
    func debugLetGoOfLevels() { levelLetGo() }
}
