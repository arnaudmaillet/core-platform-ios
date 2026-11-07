import DesignSystem
import FeedInterface
import UIKit

/// A voice message in the conversation (#2104), under its row as a photo is
/// (`ThreadMediaView`), indented to the text column:
///
/// ```
///   ▶︎   ▂▅▇▅▃▂▅▇▆▃▂▁▃▅▇▅▃▂▁▂▃   0:12  •
///  play   waveform (played | unplayed)  timer unplayed dot
/// ```
///
/// - **Its width says its length:** 140 pt at 1 s to 240 pt from 30 s.
/// - **The waveform is the message's face:** 2 pt bars, the played ones in
///   a dark grey (`ink`), re-binned from the message's 100 levels.
/// - **While it plays or is paused mid-way the speed chip stands right of
///   the timer,** coming in with a bounce (the owner's device checks,
///   2026-11-06 and 11-07); the timer counts the time played.
/// - **Its drags are its own:** one that starts on the play button or the
///   waveform goes before the list's scroll and the screen's swipes.
/// - **It draws; the screen plays** (`VoicePlayer`, one for the app): every
///   tap is told through the callbacks.
final class ThreadVoiceView: UIView, UIGestureRecognizerDelegate {
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
    /// The play button's square: the glyph alone, no glass bubble (the
    /// owner's device check, 2026-11-06 — the glass press lagged behind the
    /// tap).
    static let buttonSide: CGFloat = 32
    /// The bubble's ink — the played bars and the play glyph: a dark grey,
    /// not the brand's colour nor black (the owner, 2026-11-07).
    static let ink = UIColor.label.withAlphaComponent(0.7)
    static let barWidth: CGFloat = 2
    static let barGap: CGFloat = 2
    static let minBarHeight: CGFloat = 2
    /// The bars' full height (the owner's device check, 2026-11-06: down
    /// from 28).
    static let waveformHeight: CGFloat = 20
    /// How long a play waits on its audio before the loader replaces the
    /// pause glyph: the glyph turns on the tap, the loader only when it lasts.
    static let loaderDelay: TimeInterval = 0.4

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
    /// The app's glyph button: the symbol alone, the app's swell under the
    /// finger, a 44 pt target.
    private let playButton = AppIconButton(style: .glyph, content: .symbol("play.fill"), dims: false)
    private let loader = AppLoaderView(size: .medium)
    /// The waveform's box: the line's whole height, the bars centred in it.
    private let scrubber = UIView()
    /// The bubble ends at the unplayed dot at rest, at the speed chip under
    /// way — both right after the timer.
    private var endsAtDot: NSLayoutConstraint?
    private var endsAtChip: NSLayoutConstraint?
    let waveform = WaveformBars()
    private let timerLabel = UILabel()
    /// The app's pill (the owner's device check, 2026-11-07): its ground,
    /// its swell under the finger, its morph when the speed changes, a 44 pt
    /// target.
    private let speedChip = AppButton(aspect: .pill(.quiet), size: .row, content: .title("1×"))
    private let dot = UIView()
    private let failedLabel = UILabel()
    private var widthConstraint: NSLayoutConstraint?
    private(set) var state = State()
    private var shownGlyph = ""
    private var scrubSteps = -1
    private var pendingLoader: DispatchWorkItem?
    private let sideHold = UIPanGestureRecognizer()
    /// Whether the message shows as under way; nil until first shown.
    private var shownUnderway: Bool?
    /// Whether the speed chip stands over the bars; nil until first shown.
    private var chipShown: Bool?
    /// A finger is scrubbing the bars.
    private var isScrubbing = false
    /// A glyph set without its transition.
    private var glyphStill = false

    init() {
        super.init(frame: .zero)
        frameView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(frameView)

        // ⚠️ NO PRESSED DIMMING (`dims: false`; the owner's device check,
        // 2026-11-06, filmed): the glyph greyed under the finger kept that
        // grey through the Replace, half a second after the tap.
        playButton.symbolPointSize = 20
        playButton.inkColor = Self.ink
        // Off-up at twice the speed: the old glyph goes at once and the new
        // one is up in a tenth of a second — the default down-up shrank the
        // old one first, a third of a second behind the tap.
        playButton.symbolTransition = UISymbolContentTransition(.replace.offUp, options: .speed(2))
        // Sized here (`buttonSide`): no spring after a swap holding the new
        // glyph back.
        playButton.followsContentSize = false
        playButton.reducesMotion = { [weak self] in MotionPreference.reducesMotion || self?.glyphStill == true }
        playButton.isAccessibilityElement = false
        playButton.addAction(UIAction { [weak self] _ in self?.onPlayTap?() }, for: .primaryActionTriggered)
        // A drag that starts on the button is the button's: neither the
        // list's scroll nor the screen's swipes take it (the owner's device
        // check, 2026-11-06). It leaves the button its touches, so a press
        // that drifts is still a press.
        let hold = UIPanGestureRecognizer()
        hold.cancelsTouchesInView = false
        hold.delegate = self
        playButton.addGestureRecognizer(hold)
        // ⚠️ AND A SIDEWAYS DRAG ANYWHERE ON THE BUBBLE IS THE BUBBLE'S (the
        // owner's device check, 2026-11-06, filmed): one from the speed chip
        // went to the screen's back swipe. The screen's pans wait for this
        // one; the bubble's own run alongside it; a vertical drag scrolls.
        sideHold.cancelsTouchesInView = false
        sideHold.delegate = self
        frameView.addGestureRecognizer(sideHold)
        loader.isHidden = true

        timerLabel.font = .scaledMonospacedDigitSystemFont(
            ofSize: UIFont.defaultPointSize(for: .caption1), relativeTo: .caption1
        )
        timerLabel.adjustsFontForContentSizeCategory = true
        timerLabel.textColor = .secondaryLabel
        timerLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        speedChip.isAccessibilityElement = false
        speedChip.isHidden = true
        speedChip.addAction(UIAction { [weak self] _ in self?.onSpeedTap?() }, for: .primaryActionTriggered)

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

        for part in [playButton, loader, scrubber, waveform, timerLabel, speedChip, dot, failedLabel] as [UIView] {
            part.translatesAutoresizingMaskIntoConstraints = false
        }
        frameView.addSubview(playButton)
        playButton.addSubview(loader)
        frameView.addSubview(scrubber)
        scrubber.addSubview(waveform)
        frameView.addSubview(timerLabel)
        frameView.addSubview(dot)
        frameView.addSubview(speedChip)
        frameView.addSubview(failedLabel)
        // The bubble's line: the button's height, or the timer's when larger
        // text makes it taller — the same in every state, so playing never
        // re-lays the list.
        let line = UILayoutGuide()
        frameView.addLayoutGuide(line)

        // The length sets how many bars there are (`configure`); the bubble
        // is then as wide as what it holds — no slack beside the bars.
        let width = frameView.widthAnchor.constraint(equalToConstant: Self.maxWidth)
        width.priority = .defaultLow
        widthConstraint = width
        let boxHugsTheBars = scrubber.widthAnchor.constraint(equalTo: waveform.widthAnchor)
        boxHugsTheBars.priority = .defaultHigh
        waveform.setContentHuggingPriority(.required, for: .horizontal)
        waveform.setContentCompressionResistancePriority(.defaultHigh + 1, for: .horizontal)
        let hug = line.heightAnchor.constraint(equalToConstant: Self.buttonSide)
        hug.priority = .defaultLow
        NSLayoutConstraint.activate([
            frameView.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: CommentRowView.avatarSize + CommentRowView.avatarGap
            ),
            frameView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            frameView.topAnchor.constraint(equalTo: topAnchor),
            frameView.bottomAnchor.constraint(equalTo: bottomAnchor),
            width,

            line.topAnchor.constraint(equalTo: frameView.topAnchor),
            line.leadingAnchor.constraint(equalTo: frameView.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: frameView.trailingAnchor),
            line.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.buttonSide),
            hug,

            playButton.leadingAnchor.constraint(equalTo: frameView.leadingAnchor),
            playButton.centerYAnchor.constraint(equalTo: line.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: Self.buttonSide),
            playButton.heightAnchor.constraint(equalToConstant: Self.buttonSide),
            loader.centerXAnchor.constraint(equalTo: playButton.centerXAnchor),
            loader.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),

            boxHugsTheBars,
            scrubber.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: Spacing.sm),
            scrubber.topAnchor.constraint(equalTo: line.topAnchor),
            scrubber.bottomAnchor.constraint(equalTo: line.bottomAnchor),
            waveform.centerXAnchor.constraint(equalTo: scrubber.centerXAnchor),
            waveform.centerYAnchor.constraint(equalTo: scrubber.centerYAnchor),
            waveform.widthAnchor.constraint(lessThanOrEqualTo: scrubber.widthAnchor),
            waveform.heightAnchor.constraint(equalToConstant: Self.waveformHeight),

            timerLabel.leadingAnchor.constraint(equalTo: scrubber.trailingAnchor, constant: Spacing.sm),
            timerLabel.centerYAnchor.constraint(equalTo: line.centerYAnchor),
            line.heightAnchor.constraint(greaterThanOrEqualTo: timerLabel.heightAnchor),
            // The dot or the chip, right of the timer.
            dot.leadingAnchor.constraint(equalTo: timerLabel.trailingAnchor, constant: Spacing.xs),
            dot.centerYAnchor.constraint(equalTo: line.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            speedChip.leadingAnchor.constraint(equalTo: timerLabel.trailingAnchor, constant: Spacing.xs),
            speedChip.centerYAnchor.constraint(equalTo: line.centerYAnchor),

            failedLabel.leadingAnchor.constraint(equalTo: frameView.leadingAnchor),
            failedLabel.topAnchor.constraint(equalTo: line.bottomAnchor, constant: Spacing.xs),
        ])
        endsAtDot = dot.trailingAnchor.constraint(equalTo: frameView.trailingAnchor)
        endsAtChip = speedChip.trailingAnchor.constraint(equalTo: frameView.trailingAnchor)
        endsAtDot?.isActive = true
        let bottom = line.bottomAnchor.constraint(equalTo: frameView.bottomAnchor)
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
            setScrubbing(false, animated: false)
            pendingLoader?.cancel()
            pendingLoader = nil
            isHidden = true
            self.state = State()
            waveform.configure(levels: nil, barCount: 0, progress: 0)
            return
        }
        isHidden = false
        self.senderName = senderName
        let width = Self.width(forDuration: state.duration)
        widthConstraint?.constant = width
        let waveformWidth = width - Self.buttonSide - 2 * Spacing.sm - 34 - Spacing.xs - 6
        waveform.configure(
            levels: state.levels, barCount: Self.barCount(forWidth: waveformWidth), progress: state.progress
        )
        apply(state, animated: false)
    }

    /// Updates what changes while it plays — progress, the glyph, the chip —
    /// without re-laying the bars.
    func update(_ state: State) {
        guard !isHidden else { return }
        waveform.setProgress(state.progress)
        apply(state, animated: window != nil && !MotionPreference.reducesMotion)
    }

    private func apply(_ state: State, animated: Bool) {
        let previous = self.state
        self.state = state
        let sending = state.delivery == .sending
        let failedSend = state.delivery == .failed
        frameView.alpha = sending ? 0.5 : 1
        failedLabel.isHidden = !failedSend
        failedBottom?.isActive = failedSend

        // The glyph turns on the tap — a play waiting on its audio already
        // shows pause — and the loader takes its place only when the wait
        // lasts (the owner's device check, 2026-11-06: no delay).
        if state.playback == .loading, !sending {
            if loader.isHidden, pendingLoader == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.pendingLoader = nil
                    self?.showLoader(true)
                }
                pendingLoader = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.loaderDelay, execute: work)
            }
            setGlyph(glyphName)
        } else {
            pendingLoader?.cancel()
            pendingLoader = nil
            showLoader(sending)
        }
        playButton.isEnabled = !sending && !failedSend

        timerLabel.text = state.isUnderway
            ? Self.clock(state.duration * state.progress)
            : Self.clock(state.duration)
        // Only on a change: written every frame of playback, it restyled the
        // chip under a finger trying to press it.
        if speedChip.content.title != state.speedLabel {
            speedChip.setContent(.title(state.speedLabel), animated: animated && previous.speedLabel != state.speedLabel)
        }
        setUnderway(state.isUnderway, animated: animated && previous.isUnderway != state.isUnderway)

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

    /// What the glyph says the button does next.
    private var glyphName: String {
        if !loader.isHidden { return "" }
        return switch state.playback {
        case .failed: "arrow.clockwise"
        case .playing, .loading: "pause.fill"
        default: "play.fill"
        }
    }

    private func showLoader(_ shown: Bool) {
        loader.isHidden = !shown
        if shown { loader.startAnimating() } else { loader.stopAnimating() }
        setGlyph(glyphName)
    }

    /// The button's glyph — none while the loader stands in its place —
    /// swapped by the symbol's own Replace.
    private func setGlyph(_ name: String) {
        guard name != shownGlyph else { return }
        let animated = window != nil && !shownGlyph.isEmpty && !name.isEmpty && !MotionPreference.reducesMotion
        shownGlyph = name
        // Unanimated (a dequeued row), the glyph lands with no transition.
        glyphStill = !animated
        playButton.setContent(.symbol(name), animated: animated)
        glyphStill = false
    }

    private func setUnderway(_ underway: Bool, animated: Bool) {
        guard underway != shownUnderway else { return }
        shownUnderway = underway
        showChip(underway, animated: animated)
    }

    /// The speed chip comes in right of the timer, springing up from smaller
    /// as it fades in, and fades going: it stands there while the message is
    /// under way.
    ///
    /// ⚠️ NOTHING IS LAID OUT HERE. A spring around `layoutIfNeeded` held
    /// the play button's new glyph back until it settled (filmed, 2026-11-06).
    private func showChip(_ underway: Bool, animated: Bool) {
        guard underway != chipShown else { return }
        chipShown = underway
        // The bubble ends at what stands after the timer.
        endsAtDot?.isActive = !underway
        endsAtChip?.isActive = underway
        guard animated else {
            speedChip.layer.removeAllAnimations()
            speedChip.isHidden = !underway
            speedChip.alpha = 1
            speedChip.transform = .identity
            return
        }
        if underway {
            speedChip.isHidden = false
            speedChip.alpha = 0
            speedChip.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        }
        UIView.animate(
            withDuration: 0.45, delay: 0, usingSpringWithDamping: underway ? 0.6 : 1, initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.speedChip.alpha = underway ? 1 : 0
            self.speedChip.transform = underway ? .identity : CGAffineTransform(scaleX: 0.8, y: 0.8)
        } completion: { _ in
            guard self.chipShown == false else { return }
            self.speedChip.isHidden = true
            self.speedChip.alpha = 1
            self.speedChip.transform = .identity
        }
    }

    // MARK: - Scrubbing

    /// A finger on the bars: the whole waveform grows a little, and settles
    /// back when it lifts.
    private func setScrubbing(_ scrubbing: Bool, animated: Bool) {
        guard scrubbing != isScrubbing else { return }
        isScrubbing = scrubbing
        waveform.setSwollen(scrubbing, animated: animated)
        // The grown waveform pushes the timer and what follows it aside by
        // what it gains on its trailing side, in the same spring: never over
        // them.
        let gain = scrubbing ? (WaveformBars.swellScale - 1) / 2 * waveform.bounds.width : 0
        let aside = CGAffineTransform(translationX: gain, y: 0)
        guard animated else {
            timerLabel.transform = aside
            dot.transform = aside
            speedChip.transform = aside
            return
        }
        UIView.animate(
            springDuration: scrubbing ? WaveformBars.swellTravel : WaveformBars.settleDuration,
            bounce: scrubbing ? 0.15 : 0, options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.timerLabel.transform = aside
            self.dot.transform = aside
            self.speedChip.transform = aside
        }
    }

    private func seek(_ fraction: Double, scrubbing: Bool) {
        guard state.delivery == .sent else { return }
        setScrubbing(scrubbing, animated: window != nil && !MotionPreference.reducesMotion)
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

    /// Whether a press at `point` (own coordinates) is the bubble's: on the
    /// play button, the waveform or the speed chip — never the row's long
    /// press.
    func keepsPress(at point: CGPoint) -> Bool {
        guard !isHidden, let hit = hitTest(point, with: nil) else { return false }
        return sequence(first: hit, next: { $0.superview })
            .prefix { $0 !== self }
            .contains { $0 === playButton || $0 === waveform || $0 === speedChip }
    }

    /// The play button's hold: every other drag waits for it, so the
    /// list's scroll and the screen's swipes never take a drag that starts
    /// on the button.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        WaveformBars.yields(other, to: self) || screenPops.contains { $0 === other }
    }

    /// The bubble's own gestures — the scrub, the button's hold — run
    /// alongside its holds.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        other.view?.isDescendant(of: self) == true
    }

    /// The side hold takes only a sideways drag. (Asked as its delegate:
    /// it hangs on the bubble's frame, not on this view.)
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === sideHold else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        let velocity = sideHold.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y)
    }

    /// Whether a drag at `point` (own coordinates) starts on the bubble
    /// itself — not on the row's room beside it.
    func keepsDrag(at point: CGPoint) -> Bool {
        !isHidden && frameView.frame.contains(point)
    }

    /// The navigation's back swipes — whatever class they are, not only
    /// pans.
    private var screenPops: [UIGestureRecognizer] {
        var responder = next
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard let navigation = (responder as? UIViewController)?.navigationController else { return [] }
        return [navigation.interactivePopGestureRecognizer, navigation.interactiveContentPopGestureRecognizer]
            .compactMap { $0 }
    }

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
    var debugChipTitle: String? { speedChip.content.title }
    var debugShowsDot: Bool { !dot.isHidden }
    var debugShowsLoader: Bool { !loader.isHidden }
    var debugChipFrame: CGRect { speedChip.convert(speedChip.bounds, to: self) }
    var debugWaveformGrown: Bool { waveform.debugSwollen }
    var debugTimerFrame: CGRect { timerLabel.convert(timerLabel.bounds, to: self) }
    /// The speed chip is the app's pill.
    var debugChipIsTheAppsPill: Bool { speedChip.aspect == .pill(.quiet) }
    var debugWaveformFrame: CGRect { waveform.convert(waveform.bounds, to: self) }
    var debugScrubberFrame: CGRect { scrubber.convert(scrubber.bounds, to: self) }
    func debugSetSpeedLabel(_ label: String) {
        speedChip.setContent(.title(label), animated: false)
        layoutIfNeeded()
    }
    /// What a press at `point` (own coordinates) lands on.
    var debugSideHold: UIGestureRecognizer { sideHold }
    func debugPressTarget(at point: CGPoint) -> String {
        let hit = hitTest(point, with: nil)
        if hit === speedChip || hit?.isDescendant(of: speedChip) == true { return "chip" }
        if hit === waveform { return "waveform" }
        return "other"
    }
    /// The play button's own drag, which every other pan waits on.
    var debugPlayButtonHold: UIGestureRecognizer? {
        playButton.gestureRecognizers?.first { $0 is UIPanGestureRecognizer && $0.delegate === self }
    }
    func debugLoaderWaitEnds() {
        pendingLoader?.perform()
    }
    var debugGlyph: String { shownGlyph }
    var debugButtonImage: UIImage? { playButton.configuration?.image }
    var debugButtonSize: CGSize { playButton.bounds.size }
    /// The play button is the app's glyph button, not a system one.
    var debugPlayButtonIsTheAppsGlyph: Bool { playButton.style == .glyph }
    var debugWidth: CGFloat { widthConstraint?.constant ?? 0 }
    func debugTapPlay() { onPlayTap?() }
    func debugTapSpeed() { onSpeedTap?() }
    #endif
}

/// The voice message's waveform: 2 pt round-capped bars, the played ones in
/// a dark grey (`ink`). A tap seeks; a horizontal drag scrubs (a vertical
/// one is the list's; the row's long press does not start here). The played
/// bars are the only mark of the finger: no playhead (the owner's device
/// check, 2026-11-06).
///
/// Under a scrubbing finger the whole waveform grows a little, and settles
/// when it lifts (the owner, same day).
final class WaveformBars: UIView, UIGestureRecognizerDelegate {
    var onSeek: ((_ fraction: Double, _ scrubbing: Bool) -> Void)?

    private(set) var bars: [UInt8] = []
    private(set) var progress: Double = 0
    /// The progress drawn: it follows `progress` in a tenth of a second, so
    /// a seek or a finger never flips a bar's colour at once (the owner's
    /// device check, 2026-11-07).
    private(set) var drawnProgress: Double = 0
    private var progressLink: CADisplayLink?
    private var progressStepAt: CFTimeInterval = 0
    /// How long the drawn progress takes to close most of a gap.
    static let progressEase: CFTimeInterval = 0.08
    private var waiting = true
    private var rise: CGFloat = 1

    // MARK: The swell

    /// How much the whole waveform grows under a scrubbing finger — width
    /// and height — and how long it takes to grow and to settle.
    static let swellScale: CGFloat = 1.1
    static let swellTravel: CFTimeInterval = 0.45
    static let settleDuration: CFTimeInterval = 0.35

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
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
        drawnProgress = progress
        rise = 1
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    /// The bars' own width: the view is exactly as wide as what it draws,
    /// so whatever is centred on it is centred on the bars.
    var barsWidth: CGFloat {
        bars.isEmpty ? 0 : CGFloat(bars.count) * (ThreadVoiceView.barWidth + ThreadVoiceView.barGap) - ThreadVoiceView.barGap
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: barsWidth, height: UIView.noIntrinsicMetric)
    }

    func setProgress(_ progress: Double) {
        guard abs(progress - self.progress) > 0.0005 else { return }
        self.progress = progress
        guard window != nil, !MotionPreference.reducesMotion else {
            drawnProgress = progress
            return setNeedsDisplay()
        }
        guard progressLink == nil else { return }
        progressStepAt = CACurrentMediaTime()
        let link = CADisplayLink(target: RiseStep { [weak self] link in
            guard let self else { return link.invalidate() }
            stepProgress()
        }, selector: #selector(RiseStep.fire(_:)))
        link.add(to: .main, forMode: .common)
        progressLink = link
    }

    /// Eases the drawn progress toward the real one, frame by frame.
    private func stepProgress() {
        let now = CACurrentMediaTime()
        let dt = now - progressStepAt
        progressStepAt = now
        let gap = progress - drawnProgress
        if abs(gap) < 0.0005 {
            drawnProgress = progress
            progressLink?.invalidate()
            progressLink = nil
        } else {
            drawnProgress += gap * (1 - exp(-dt / Self.progressEase))
        }
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

    /// Drawn finer than the screen, so the bars stay sharp grown.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        let screen = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        contentScaleFactor = screen * Self.swellScale
    }

    override func draw(_ rect: CGRect) {
        guard !bars.isEmpty else { return }
        let step = ThreadVoiceView.barWidth + ThreadVoiceView.barGap
        // A bar fills by the share of it the progress has covered: the one
        // under the finger blends, none flips.
        let reached = drawnProgress * Double(bars.count)
        let played = ThreadVoiceView.ink.resolvedColor(with: traitCollection)
        let unplayed = UIColor.tertiaryLabel.resolvedColor(with: traitCollection)
        for (index, level) in bars.enumerated() {
            let full = waiting ? 0 : CGFloat(level) / 31 * bounds.height * rise
            let height = max(ThreadVoiceView.minBarHeight, full)
            let bar = CGRect(
                x: CGFloat(index) * step, y: (bounds.height - height) / 2,
                width: ThreadVoiceView.barWidth, height: height
            )
            let share = CGFloat(min(1, max(0, reached - Double(index))))
            Self.blend(unplayed, played, share).setFill()
            UIBezierPath(roundedRect: bar, cornerRadius: ThreadVoiceView.barWidth / 2).fill()
        }
    }

    /// `from` to `to`, `share` of the way, channel by channel.
    static func blend(_ from: UIColor, _ to: UIColor, _ share: CGFloat) -> UIColor {
        guard share > 0 else { return from }
        guard share < 1 else { return to }
        var a = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
        var b = a
        from.getRed(&a.r, green: &a.g, blue: &a.b, alpha: &a.a)
        to.getRed(&b.r, green: &b.g, blue: &b.b, alpha: &b.a)
        return UIColor(
            red: a.r + (b.r - a.r) * share, green: a.g + (b.g - a.g) * share,
            blue: a.b + (b.b - a.b) * share, alpha: a.a + (b.a - a.a) * share
        )
    }

    // MARK: - The swell

    /// The finger landed (true): the whole waveform grows. It lifted
    /// (false): it settles back.
    func setSwollen(_ swollen: Bool, animated: Bool) {
        let size: CGAffineTransform = swollen ? CGAffineTransform(scaleX: Self.swellScale, y: Self.swellScale) : .identity
        guard animated else {
            transform = size
            return
        }
        UIView.animate(
            springDuration: swollen ? Self.swellTravel : Self.settleDuration, bounce: swollen ? 0.15 : 0,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.transform = size
        }
    }

    // MARK: - Seeking

    private func fraction(at point: CGPoint) -> Double {
        Double(min(1, max(0, point.x / max(1, min(barsWidth, bounds.width)))))
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        onSeek?(fraction(at: tap.location(in: self)), false)
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let fraction = fraction(at: pan.location(in: self))
        switch pan.state {
        case .began, .changed:
            onSeek?(fraction, true)
        default:
            onSeek?(fraction, false)
        }
    }

    /// Only a horizontal drag scrubs.
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y)
    }

    /// A horizontal drag on the bars goes before the list's scroll and the
    /// screen's swipes, which wait for it to fail.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        // Not the bubble's own holds: waiting on the scrub, they failed when
        // it began and let the screen's swipes through.
        guard !(other.delegate is ThreadVoiceView) else { return false }
        return Self.yields(other, to: self)
    }

    /// Whether `other` waits for a voice message's own drag: any pan that
    /// is not the bubble's — the list's scroll, the content pop, the
    /// screen's swipe stages.
    static func yields(_ other: UIGestureRecognizer, to view: UIView) -> Bool {
        guard other is UIPanGestureRecognizer, let owner = other.view else { return false }
        return !owner.isDescendant(of: view)
    }

    private final class RiseStep: NSObject {
        let action: (CADisplayLink) -> Void
        init(_ action: @escaping (CADisplayLink) -> Void) { self.action = action }
        @objc func fire(_ link: CADisplayLink) { action(link) }
    }

    #if DEBUG
    var debugWaiting: Bool { waiting }
    var debugSwollen: Bool { transform != .identity }
    #endif
}
