import AVFoundation
import Foundation

/// THE FEED'S SOUND (#1931, the owner 2026-10-30): Instagram's model, with no
/// in-app mute.
///
/// **The feed follows the device until the viewer presses a volume key; then
/// it is heard for the session.**
///
/// - At launch the session is `.ambient` (`VideoPlaybackController`): the
///   Ring/Silent switch silences it, and it mixes with other apps' audio.
/// - A volume key pressed while a feed plays turns the sound ON for the rest
///   of the launch: the pool's session becomes `.playback`, heard through the
///   silent switch (`VideoPlaybackController.settleAudioSession`).
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

    /// The volume's observation while listening — a token kept alive.
    private var observation: AnyObject?
    private let readsOtherAudio: @MainActor () -> Bool
    private let startsObserving: (@escaping @MainActor () -> Void) -> AnyObject?

    /// - Parameters:
    ///   - otherAudioPlaying: whether another app's audio holds the speaker.
    ///   - observe: starts observing the system volume; the default observes
    ///     `AVAudioSession.outputVolume`. Tests pass their own and report a
    ///     change through `volumeDidChange()`.
    public init(
        otherAudioPlaying: @escaping @MainActor () -> Bool = {
            let session = AVAudioSession.sharedInstance()
            return session.isOtherAudioPlaying || session.secondaryAudioShouldBeSilencedHint
        },
        observe: @escaping (@escaping @MainActor () -> Void) -> AnyObject? = { changed in
            AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { _, _ in
                Task { @MainActor in changed() }
            }
        }
    ) {
        readsOtherAudio = otherAudioPlaying
        startsObserving = observe
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
        guard !watchers.isEmpty, !isTurnedOn else {
            observation = nil
            return
        }
        guard observation == nil else { return }
        observation = startsObserving { [weak self] in self?.volumeDidChange() }
    }

    /// The system volume moved: a volume key. Turns the sound on for the
    /// session, unless another app's audio is what the key was about.
    public func volumeDidChange() {
        guard !isTurnedOn, !readsOtherAudio() else { return }
        isTurnedOn = true
        observation = nil
        NotificationCenter.default.post(name: Self.didTurnOn, object: self)
    }

    #if DEBUG
    /// Tests start from a fresh launch.
    public func debugReset() {
        isTurnedOn = false
        observation = nil
        watchers = []
    }
    #endif
}
