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

    public init(
        session: any VoiceAudioSessionControlling = AVAudioSession.sharedInstance(),
        makeEngine: @escaping () -> any VoicePlaybackEngine = { AVPlayerEngine() },
        defaults: UserDefaults = .standard,
        notifications: NotificationCenter = .default
    ) {
        self.session = session
        self.makeEngine = makeEngine
        self.defaults = defaults
        self.notifications = notifications
        speed = VoicePlaybackSpeed(rawValue: defaults.double(forKey: Self.speedKey)) ?? .normal
        observeInterruptions()
    }

    /// Plays message `id` from `url` — from where it was paused when it is
    /// the one paused, from `fraction` of it otherwise (a message left
    /// mid-way and come back to), stopping any other.
    public func play(_ id: String, url: URL, from fraction: Double? = nil) {
        if id == messageID, let engine, state == .paused || state == .playing {
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

    public func pause() {
        guard state == .playing || state == .loading, let engine else { return }
        cancelStart()
        engine.pause()
        stopLink()
        releaseFocus()
        set(.paused)
    }

    /// Plays or pauses message `id`.
    public func toggle(_ id: String, url: URL) {
        if id == messageID, state == .playing { pause() } else { play(id, url: url) }
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
        waitingStart = token
        session.activate(.listening) { [weak self] error in
            guard let self, token == startToken, waitingStart == token, let engine = self.engine else { return }
            waitingStart = nil
            if error != nil {
                failed()
                return
            }
            engine.play(rate: Float(speed.rawValue))
            set(.playing)
            startLink()
        }
        // Still waiting: a resume shows it is on its way.
        if waitingStart == token, state == .paused { set(.loading) }
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
        guard !holdsFocus else { return }
        holdsFocus = true
        notifications.post(name: VoiceAudioFocus.didTake, object: self)
    }

    private func releaseFocus() {
        guard holdsFocus else { return }
        holdsFocus = false
        session.deactivate()
        notifications.post(name: VoiceAudioFocus.didRelease, object: self)
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
                MainActor.assumeIsolated { if began { self?.pause() } }
            },
            notifications.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) {
                [weak self] note in
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                    .flatMap(AVAudioSession.RouteChangeReason.init)
                // Headphones out: never on to the speaker for the room.
                MainActor.assumeIsolated { if reason == .oldDeviceUnavailable { self?.pause() } }
            },
            // A take starting pauses the message playing.
            notifications.addObserver(forName: VoiceAudioFocus.didTake, object: nil, queue: .main) {
                [weak self] note in
                let taker = (note.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, taker != ObjectIdentifier(self) else { return }
                    self.pause()
                }
            },
        ]
    }
}
