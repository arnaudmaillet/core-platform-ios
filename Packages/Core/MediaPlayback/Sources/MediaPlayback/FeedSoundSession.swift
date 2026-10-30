import AudioToolbox
import AVFoundation
import Foundation
import QuartzCore

/// THE FEED'S SOUND (#1931, the owner 2026-10-30): Instagram's model, with no
/// in-app mute.
///
/// **The feed follows the device until the viewer presses a volume key; then
/// it is heard — until the phone is put on silent again.**
///
/// - At launch the session is `.ambient` (`VideoPlaybackController`): the
///   Ring/Silent switch silences it, and it mixes with other apps' audio.
/// - A volume key pressed while a feed plays turns the sound ON: the pool's
///   session becomes `.playback`, heard through the silent switch
///   (`VideoPlaybackController.settleAudioSession`).
/// - Putting the phone on silent again turns it OFF (the owner, 2026-10-30,
///   as Instagram does): back to `.ambient`, which the switch silences, and
///   a volume key turns it on again (`RingerProbe`).
/// - Never over another app's audio: with music playing, a volume key is
///   about that music, and the feed stays `.ambient`, mixed.
///
/// ⚠️ THE SILENT SWITCH CANNOT BE READ (Apple QA1692), and there is no
/// volume-key API. What is observed is `AVAudioSession.outputVolume` (public,
/// key-value observable): a key moves it. Known limits — at the top of the
/// range volume up moves nothing (and at zero volume down), so the viewer
/// presses the other key; the simulator reports no change; and if a future
/// iOS stops reporting it, the feed simply stays `.ambient` — it fails safe,
/// towards silence. The viewer's volume is never moved to make the keys
/// detectable.
@MainActor
public final class FeedSoundSession {
    /// The app's one session: every feed screen reads and watches it.
    public static let shared = FeedSoundSession()

    /// Whether the viewer turned the sound on this launch (a volume key).
    public private(set) var isTurnedOn = false

    /// Posted on the main queue when the sound is turned on.
    public static let didTurnOn = Notification.Name("FeedSoundSession.didTurnOn")
    /// Posted on the main queue when the phone was put on silent again.
    public static let didTurnOff = Notification.Name("FeedSoundSession.didTurnOff")

    /// The volume's observation while listening — a token kept alive.
    private var observation: AnyObject?
    /// The ringer's checks while the sound is on — a token kept alive.
    private var ringerTicks: AnyObject?
    /// Whether a ringer check is under way.
    private var isProbing = false
    /// What the last ringer check read since the sound was turned on: nil
    /// before the first.
    private var lastReadSilent: Bool?
    private let readsOtherAudio: @MainActor () -> Bool
    private let startsObserving: (@escaping @MainActor () -> Void) -> AnyObject?
    private let probesSilent: @MainActor (@escaping @MainActor @Sendable (Bool) -> Void) -> Void
    private let startsTicking: (@escaping @MainActor () -> Void) -> AnyObject?

    /// - Parameters:
    ///   - otherAudioPlaying: whether another app's audio holds the speaker.
    ///   - observe: starts observing the system volume; the default observes
    ///     `AVAudioSession.outputVolume`. Tests pass their own and report a
    ///     change through `volumeDidChange()`.
    ///   - probeSilent: tells whether the phone is on silent (`RingerProbe`).
    ///   - tick: starts the ringer's checks while the sound is on, once a
    ///     second by default.
    public init(
        otherAudioPlaying: @escaping @MainActor () -> Bool = {
            let session = AVAudioSession.sharedInstance()
            return session.isOtherAudioPlaying || session.secondaryAudioShouldBeSilencedHint
        },
        observe: @escaping (@escaping @MainActor () -> Void) -> AnyObject? = { changed in
            let session = AVAudioSession.sharedInstance()
            // ⚠️ `outputVolume` reports only while the session is ACTIVE: on a
            // silent phone before anything plays, the first key would go
            // unseen. Active under `.ambient`, which mixes — another app's
            // music keeps playing.
            try? session.setActive(true)
            return session.observe(\.outputVolume, options: [.new]) { _, _ in
                Task { @MainActor in changed() }
            }
        },
        probeSilent: @escaping @MainActor (@escaping @MainActor @Sendable (Bool) -> Void) -> Void = RingerProbe.probe,
        tick: @escaping (@escaping @MainActor () -> Void) -> AnyObject? = { fire in
            // In the common modes: a feed being scrolled still checks.
            let timer = Timer(timeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { fire() }
            }
            RunLoop.main.add(timer, forMode: .common)
            return timer
        }
    ) {
        readsOtherAudio = otherAudioPlaying
        startsObserving = observe
        probesSilent = probeSilent
        startsTicking = tick
    }

    /// Whether a volume key is listened for now.
    public var isWatching: Bool { observation != nil }

    /// The feed screens that own the sound now: on screen, in the
    /// foreground, playing. Per screen, so one leaving under another that
    /// arrived does not stop the other's watch.
    private var watchers: Set<ObjectIdentifier> = []

    /// Listens for a volume key while a feed screen is on screen, in the
    /// foreground, with its sound playing — and only until the sound is on.
    public func setWatching(_ watching: Bool, by owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        if watching { watchers.insert(key) } else { watchers.remove(key) }
        settleWatch()
    }

    /// What is listened for now: a volume key while the sound is off, the
    /// ringer while it is on — and nothing with no feed playing.
    private func settleWatch() {
        if watchers.isEmpty || isTurnedOn {
            observation = nil
        } else if observation == nil {
            observation = startsObserving { [weak self] in self?.volumeDidChange() }
        }
        if watchers.isEmpty || !isTurnedOn {
            stopRingerTicks()
        } else if ringerTicks == nil {
            ringerTicks = startsTicking { [weak self] in self?.checkRinger() }
        }
    }

    private func stopRingerTicks() {
        (ringerTicks as? Timer)?.invalidate()
        ringerTicks = nil
    }

    /// One ringer check, unless one is under way.
    func checkRinger() {
        guard isTurnedOn, !isProbing else { return }
        isProbing = true
        probesSilent { [weak self] silent in
            guard let self else { return }
            isProbing = false
            ringerRead(silent: silent)
        }
    }

    /// ⚠️ A CHANGE TO SILENT, NEVER THE STATE. A phone already on silent is
    /// where a volume key matters most — the viewer reaching for the sound
    /// through the switch — and reading "silent" there would turn it off a
    /// second after the key. Only the switch moving from ring to silent, with
    /// the sound on, turns it off.
    func ringerRead(silent: Bool) {
        guard isTurnedOn else { return }
        defer { lastReadSilent = silent }
        guard silent, lastReadSilent == false else { return }
        ringerWentSilent()
    }

    /// The phone was put on silent with the sound on: off again, and the
    /// next volume key turns it back on.
    private func ringerWentSilent() {
        isTurnedOn = false
        lastReadSilent = nil
        settleWatch()
        NotificationCenter.default.post(name: Self.didTurnOff, object: self)
    }

    /// The system volume moved: a volume key. Turns the sound on for the
    /// session, unless another app's audio is what the key was about.
    public func volumeDidChange() {
        guard !isTurnedOn, !readsOtherAudio() else { return }
        isTurnedOn = true
        lastReadSilent = nil
        settleWatch()
        NotificationCenter.default.post(name: Self.didTurnOn, object: self)
    }

    /// Whether the ringer is being checked now. Tests.
    var isCheckingRinger: Bool { ringerTicks != nil }

    #if DEBUG
    /// Tests start from a fresh launch.
    public func debugReset() {
        isTurnedOn = false
        observation = nil
        stopRingerTicks()
        watchers = []
    }
    #endif
}

/// Whether the phone is on silent (#1931), with public API only.
///
/// ⚠️ THE SWITCH ITSELF CANNOT BE READ (Apple QA1692). What can: a system
/// sound obeys the Ring/Silent switch whatever the app's session, and on
/// silent the system skips it, calling its completion AT ONCE. So a short
/// silent sound is played, and a completion well before its length means the
/// phone is on silent. Nothing is ever heard: the sound is silence.
///
/// Known limits, filmed on a device: if a future iOS calls the completion at
/// once either way, every check reads "silent" and the sound turns off after
/// a second — towards silence, the safe side; if it never calls it, the
/// check never ends and the sound stays on until relaunch.
public enum RingerProbe {
    /// The silent sound's length, and the completion's floor under which the
    /// sound was skipped.
    static let soundLength: Double = 0.4
    static let skippedBelow: CFTimeInterval = 0.1

    /// The silent sound, written once to the caches; nil if it could not be.
    private static let soundID: SystemSoundID? = makeSound()

    /// Calls `done` on the main actor with whether the phone is on silent.
    @MainActor public static func probe(_ done: @escaping @MainActor @Sendable (Bool) -> Void) {
        // No sound to time: the switch cannot be read, so it reads "ringing"
        // and the sound stays as the viewer set it.
        guard let soundID else { return done(false) }
        let start = CACurrentMediaTime()
        AudioServicesPlaySystemSoundWithCompletion(soundID, completion(start: start, done))
    }

    /// ⚠️ BUILT OUTSIDE THE MAIN ACTOR, ON PURPOSE: the system calls the
    /// completion on its own thread, and a closure written in main-actor
    /// code is main-actor isolated — Swift 6 traps when it runs elsewhere.
    private nonisolated static func completion(
        start: CFTimeInterval, _ done: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> @Sendable () -> Void {
        { [done] in
            let elapsed = CACurrentMediaTime() - start
            Task { @MainActor in
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-sound-log") {
                    print(String(format: "[sound] ringer check %.3f s → %@", elapsed, elapsed < skippedBelow ? "silent" : "ringing"))
                }
                #endif
                done(elapsed < skippedBelow)
            }
        }
    }

    /// A mono 16-bit WAV of silence, `soundLength` long.
    private nonisolated static func makeSound() -> SystemSoundID? {
        let rate = 44_100
        let samples = Int(Double(rate) * soundLength)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + samples * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(rate))
        append(UInt32(rate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(samples * 2))
        data.append(Data(count: samples * 2))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ringer-probe.wav")
        guard (try? data.write(to: url)) != nil else { return nil }
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr else { return nil }
        return id
    }
}
