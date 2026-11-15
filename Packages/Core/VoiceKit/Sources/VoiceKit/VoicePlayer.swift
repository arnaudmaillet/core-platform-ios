import AVFoundation
import UIKit

/// The speeds a voice message plays at — one app-wide choice, pitch kept.
public enum VoicePlaybackSpeed: Double, CaseIterable, Sendable {
    case normal = 1
    case fast = 1.5
    case faster = 2

    /// The speed's words (#2364): "1×", "1.5×", "2×".
    public var label: String {
        switch self {
        case .normal: "1×"
        case .fast: "1.5×"
        case .faster: "2×"
        }
    }

    /// The next speed a tap on the speed's words picks, round.
    public var next: VoicePlaybackSpeed {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// What plays a file — `AVPlayer` in the app, a fake in tests.
@MainActor
public protocol VoicePlaybackEngine: AnyObject {
    func load(_ url: URL)
    func play(rate: Float)
    func pause()
    func seek(to seconds: TimeInterval)
    var currentTime: TimeInterval { get }
    /// Nil until the file says.
    var duration: TimeInterval? { get }
    /// Told when the file has played to its end, and when it failed.
    var onEnd: (() -> Void)? { get set }
    var onFailure: (() -> Void)? { get set }
}

@MainActor
public final class AVPlayerEngine: VoicePlaybackEngine {
    private let player = AVPlayer()
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    public var onEnd: (() -> Void)?
    public var onFailure: (() -> Void)?

    public init() {
        player.automaticallyWaitsToMinimizeStalling = false
    }

    public func load(_ url: URL) {
        let item = AVPlayerItem(url: url)
        // ⚠️ THE PITCH IS KEPT at 1.5× and 2×: time-domain stretching, the
        // one meant for speech.
        item.audioTimePitchAlgorithm = .timeDomain
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnd?() }
        }
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async { self?.onFailure?() }
        }
        player.replaceCurrentItem(with: item)
    }

    public func play(rate: Float) {
        player.playImmediately(atRate: rate)
    }

    public func pause() { player.pause() }

    public func seek(to seconds: TimeInterval) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public var currentTime: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    public var duration: TimeInterval? {
        guard let seconds = player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }
}

/// The app's ONE voice player (#2101): at most one voice message plays at a
/// time — starting one stops the one playing.
///
/// - **The session is the listening role** (spoken audio, the silent switch
///   ignored); the feed's video and the sound sheet's track pause while it
///   plays (`VoiceAudioFocus`) and get the sound back when it pauses or ends.
/// - **A call, Siri or an alarm pauses it, and so do headphones coming
///   out.** Nothing resumes on its own.
/// - **The speed is one app-wide choice, remembered across launches**, and
///   applied to whatever plays.
/// - **The position is told at the display's rate while it plays**
///   (`onChange`), for the row's waveform and timer.
/// - **Fast taps follow the last one (#2414).** A tap while the audio is on
///   its way pauses it (the start is cancelled, the place kept); a voice
///   already loaded is never loaded again, so the place never moves back.
/// - **A pause keeps the session a moment (`releaseGrace`)**: a resume
///   inside it plays at once. A call, Siri, headphones out, another take or
///   the background release at once.
@MainActor
public final class VoicePlayer {
    public enum State: Equatable, Sendable {
        case idle, loading, playing, paused, ended, failed
    }

    public static let shared = VoicePlayer()

    static let speedKey = "voice.playbackSpeed"

    public private(set) var state: State = .idle
    /// The message playing, paused or just ended — nil when idle.
    public private(set) var messageID: String?
    public private(set) var speed: VoicePlaybackSpeed
    /// Seconds played, and the file's length once known.
    public var currentTime: TimeInterval { engine?.currentTime ?? 0 }
    public var duration: TimeInterval? { engine?.duration }
    /// How far it is, 0…1, nil with no length yet.
    public var progress: Double? {
        guard let duration, duration > 0 else { return nil }
        return min(1, max(0, currentTime / duration))
    }

    /// Every change of state, message or speed, and the position while
    /// playing, at the display's rate.
    public var onChange: (() -> Void)?

    /// Posted with every `onChange` (#2205): the one closure is the
    /// conversation's; the voice posts' views — several on one id, a card
    /// and the post's page — listen here.
    public static let didChange = Notification.Name("VoicePlayer.didChange")

    private func changed() {
        onChange?()
        notifications.post(name: Self.didChange, object: self)
    }

    private let session: any VoiceAudioSessionControlling
    private let makeEngine: () -> any VoicePlaybackEngine
    private let defaults: UserDefaults
    private let notifications: NotificationCenter
    private var engine: (any VoicePlaybackEngine)?
    private var link: CADisplayLink?
    private var observers: [NSObjectProtocol] = []
    private var holdsFocus = false
    /// A seek asked before the file said its length: applied once it does.
    private var pendingFraction: Double?

    /// ⚠️ HOW LONG A PAUSE KEEPS THE SESSION AND THE FOCUS (#2414). Each
    /// pause gave the session back and each resume took it again, a wait
    /// every time: at several taps a second, every tap was a deactivate /
    /// activate round, and the feed's video took the sound back between
    /// two taps. Inside the grace a resume plays at once, with no
    /// activation; past it the session goes back and the video's sound
    /// returns, as before. A release the system asks for never waits.
    public static let releaseGrace: TimeInterval = 1.5
    /// Counts `releaseGrace` after a pause (a timer in the app, a manual
    /// ticker in tests).
    private let graceTimer: any VoiceTicking
    /// A release waiting out the grace.
    public private(set) var releasePending = false
    /// The session is ours: taken, and not given back since. A start then
    /// plays at once.
    private var sessionTaken = false
    /// Counts the releases: an activation answered after one doesn't count
    /// as the session taken.
    private var releaseCount = 0

    public init(
        session: any VoiceAudioSessionControlling = AVAudioSession.sharedInstance(),
        makeEngine: @escaping () -> any VoicePlaybackEngine = { AVPlayerEngine() },
        defaults: UserDefaults = .standard,
        notifications: NotificationCenter = .default,
        graceTimer: any VoiceTicking = TimerTicker()
    ) {
        self.session = session
        self.makeEngine = makeEngine
        self.defaults = defaults
        self.notifications = notifications
        self.graceTimer = graceTimer
        speed = VoicePlaybackSpeed(rawValue: defaults.double(forKey: Self.speedKey)) ?? .normal
        observeInterruptions()
    }

    /// Plays message `id` from `url` — from where it was paused when it is
    /// the one paused, from `fraction` of it otherwise (a message left
    /// mid-way and come back to), stopping any other.
    ///
    /// ⚠️ A VOICE ALREADY LOADED IS NEVER LOADED AGAIN (#2414). From
    /// `.loading` a play made a new engine and loaded the file again, from
    /// `fraction` — a place remembered at an older pause, or none — and the
    /// voice jumped back, to 0 at worst (the owner's recording). Loaded
    /// (`.loading`, `.paused`, `.playing`), it goes on from where it is and
    /// `fraction` is not read. A new engine only for another voice, after a
    /// failure, the end or `stop`.
    public func play(_ id: String, url: URL, from fraction: Double? = nil) {
        if id == messageID, let engine, state == .paused || state == .playing || state == .loading {
            if state == .paused { start(engine) }
            return
        }
        stop()
        let engine = makeEngine()
        engine.onEnd = { [weak self] in self?.ended() }
        engine.onFailure = { [weak self] in self?.failed() }
        self.engine = engine
        messageID = id
        set(.loading)
        engine.load(url)
        if let fraction, fraction > 0, fraction < 1 { seek(to: fraction) }
        start(engine)
    }

    /// Silent at once, where it is. A start still waiting on the session is
    /// cancelled. The session and the focus go back after `releaseGrace`, or
    /// at once with `releaseAtOnce` (the app going to the background).
    public func pause(releaseAtOnce: Bool = false) {
        guard state == .playing || state == .loading, let engine else { return }
        cancelStart()
        engine.pause()
        stopLink()
        if releaseAtOnce { releaseFocus() } else { releaseAfterGrace() }
        set(.paused)
    }

    /// Plays or pauses message `id`. ⚠️ ON THE INTENT, NOT THE SOUND (#2414):
    /// a voice on its way (`.loading`) is a voice playing, so a tap then
    /// pauses it — it used to start it again.
    public func toggle(_ id: String, url: URL) {
        if id == messageID, state == .playing || state == .loading { pause() } else { play(id, url: url) }
    }

    /// Moves the message on show to `fraction` of its length.
    public func seek(to fraction: Double) {
        guard let engine else { return }
        let fraction = min(1, max(0, fraction))
        guard let duration = engine.duration else {
            pendingFraction = fraction
            return
        }
        pendingFraction = nil
        engine.seek(to: duration * fraction)
        if state == .ended { set(.paused) } else { changed() }
    }

    /// The app-wide speed, applied now to what plays and kept.
    public func setSpeed(_ speed: VoicePlaybackSpeed) {
        self.speed = speed
        defaults.set(speed.rawValue, forKey: Self.speedKey)
        if state == .playing { engine?.play(rate: Float(speed.rawValue)) }
        changed()
    }

    /// Stops and forgets the message on show.
    public func stop() {
        cancelStart()
        engine?.pause()
        engine = nil
        pendingFraction = nil
        stopLink()
        releaseFocus()
        messageID = nil
        set(.idle)
    }

    // MARK: - Playing

    /// Counts the starts: a session taken after a pause, a stop or another
    /// start doesn't play (#2329).
    private var startToken = 0
    /// The start still waiting on the session, if any.
    private var waitingStart: Int?

    /// Plays once the session is taken (#2329). ⚠️ NEVER ON THE MAIN
    /// THREAD'S TIME: the system's session is taken off it
    /// (`activate(_:then:)`), the state staying `.loading` meanwhile — a
    /// resume says `.loading` too while it waits — so the panel's morph and
    /// glyph swap run their course instead of freezing for the half second
    /// the activation took on main and then cutting to their end. A fake
    /// session answers at once: the same turn, as before.
    private func start(_ engine: any VoicePlaybackEngine) {
        takeFocus()
        startToken += 1
        let token = startToken
        // Still ours, a pause's grace not run out (#2414): it plays at once.
        if sessionTaken {
            waitingStart = nil
            playNow(engine)
            return
        }
        waitingStart = token
        let releases = releaseCount
        session.activate(.listening) { [weak self] error in
            guard let self else { return }
            if error == nil, releases == releaseCount { sessionTaken = true }
            guard token == startToken, waitingStart == token, let engine = self.engine else { return }
            waitingStart = nil
            if error != nil {
                failed()
                return
            }
            playNow(engine)
        }
        // Still waiting: a resume shows it is on its way.
        if waitingStart == token, state == .paused { set(.loading) }
    }

    /// Sounds, at the speed, from where it is.
    private func playNow(_ engine: any VoicePlaybackEngine) {
        engine.play(rate: Float(speed.rawValue))
        set(.playing)
        startLink()
    }

    /// No start waiting on the session plays any more.
    private func cancelStart() {
        startToken += 1
        waitingStart = nil
    }

    private func ended() {
        stopLink()
        releaseFocus()
        set(.ended)
    }

    private func failed() {
        cancelStart()
        engine?.pause()
        stopLink()
        releaseFocus()
        set(.failed)
    }

    private func set(_ state: State) {
        self.state = state
        changed()
    }

    // MARK: - Focus

    private func takeFocus() {
        // A resume inside a pause's grace keeps what it holds.
        if releasePending {
            graceTimer.stop()
            releasePending = false
        }
        guard !holdsFocus else { return }
        holdsFocus = true
        notifications.post(name: VoiceAudioFocus.didTake, object: self)
    }

    /// Gives the session and the focus back now, a grace waiting or not.
    private func releaseFocus() {
        if releasePending {
            graceTimer.stop()
            releasePending = false
        }
        guard holdsFocus else { return }
        holdsFocus = false
        sessionTaken = false
        releaseCount += 1
        session.deactivate()
        notifications.post(name: VoiceAudioFocus.didRelease, object: self)
    }

    /// Gives them back once `releaseGrace` has passed with no resume.
    private func releaseAfterGrace() {
        guard holdsFocus else { return }
        releasePending = true
        graceTimer.start(interval: Self.releaseGrace) { [weak self] in
            guard let self, releasePending else { return }
            releaseFocus()
        }
    }

    /// The system asked (a call, Siri, an alarm, headphones out) or another
    /// take started: paused if it plays, and released at once — a grace
    /// under way included, so the next one never finds the session gone
    /// from under it.
    private func interrupted() {
        if state == .playing || state == .loading {
            pause(releaseAtOnce: true)
        } else {
            releaseFocus()
        }
    }

    // MARK: - The position

    private func startLink() {
        guard link == nil else { return }
        let link = CADisplayLink(target: LinkTarget { [weak self] in self?.tick() }, selector: #selector(LinkTarget.fire))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Every display frame while it plays: a seek waiting on the length,
    /// then the position.
    func tick() {
        if let pendingFraction, let engine, let duration = engine.duration {
            self.pendingFraction = nil
            engine.seek(to: duration * pendingFraction)
        }
        changed()
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    private final class LinkTarget: NSObject {
        let action: @MainActor () -> Void
        init(_ action: @escaping @MainActor () -> Void) { self.action = action }
        @MainActor @objc func fire() { action() }
    }

    // MARK: - Interruptions

    private func observeInterruptions() {
        observers = [
            notifications.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) {
                [weak self] note in
                let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                    .flatMap(AVAudioSession.InterruptionType.init) == .began
                MainActor.assumeIsolated { if began { self?.interrupted() } }
            },
            notifications.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) {
                [weak self] note in
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                    .flatMap(AVAudioSession.RouteChangeReason.init)
                // Headphones out: never on to the speaker for the room.
                MainActor.assumeIsolated { if reason == .oldDeviceUnavailable { self?.interrupted() } }
            },
            // A take starting pauses the message playing.
            notifications.addObserver(forName: VoiceAudioFocus.didTake, object: nil, queue: .main) {
                [weak self] note in
                let taker = (note.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, taker != ObjectIdentifier(self) else { return }
                    self.interrupted()
                }
            },
        ]
    }
}
