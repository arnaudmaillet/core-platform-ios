import AVFoundation
import UIKit

/// The audio session as the voice engine drives it — `AVAudioSession` in the
/// app, a fake in tests, so the categories and options are checked without
/// a device.
@MainActor
public protocol VoiceAudioSessionControlling: AnyObject {
    func setCategory(
        _ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions
    ) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
    /// Whether a microphone is there to record from.
    var isInputAvailable: Bool { get }
    /// Takes the session — after any release already under way.
    func activate() throws
    /// Takes the session in `role` and says so on the main thread, with the
    /// error if it could not (#2329). The system's session does it OFF the
    /// main thread: taking it held the main thread about half a second, so a
    /// voice's tap froze the panel's morph and its glyph's swap mid-motion
    /// and then cut them to their end. A fake answers at once.
    func activate(
        _ role: VoiceSessionRole, then completion: @escaping @MainActor @Sendable (_ error: (any Error)?) -> Void
    )
    /// Gives the session back, telling the others they may play again.
    func deactivate()
    /// Whether haptics still play while it records — iOS mutes them by
    /// default, and the lock's tap went unfelt (the owner, 2026-11-07).
    func setAllowHapticsAndSystemSoundsDuringRecording(_ allow: Bool) throws
}

public extension VoiceAudioSessionControlling {
    func activate() throws { try setActive(true, options: []) }
    func activate(
        _ role: VoiceSessionRole, then completion: @escaping @MainActor @Sendable (_ error: (any Error)?) -> Void
    ) {
        do {
            try role.apply(to: self)
            completion(nil)
        } catch {
            completion(error)
        }
    }
    func deactivate() { try? setActive(false, options: .notifyOthersOnDeactivation) }
    func setAllowHapticsAndSystemSoundsDuringRecording(_ allow: Bool) throws {}
}

/// ⚠️ THE RELEASE NEVER HOLDS THE MAIN THREAD. On a device, deactivating with
/// `.notifyOthersOnDeactivation` took 0.6 s, every time (0.7 ms on the
/// simulator): a voice message's pause showed that long after the tap
/// (measured, the owner's iPhone, 2026-11-06). It goes on `VoiceSessionLine`;
/// an activation goes the same way, so it never lands before a release.
extension AVAudioSession: VoiceAudioSessionControlling {
    public func activate() throws {
        try VoiceSessionLine.shared.claim {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        }
    }

    public func deactivate() {
        VoiceSessionLine.shared.release {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// ⚠️ THE CLAIM FOR A PLAY NEVER HOLDS THE MAIN THREAD EITHER (#2329):
    /// the category and the activation, on the line, then `completion` on
    /// the main thread. Held on main, they froze a voice's first frames for
    /// about half a second — the panel's morph and its glyph's swap stood
    /// still and then cut to their end (filmed, 60 fps, 2026-11-11).
    public func activate(
        _ role: VoiceSessionRole, then completion: @escaping @MainActor @Sendable (_ error: (any Error)?) -> Void
    ) {
        VoiceSessionLine.shared.claim(async: {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(role.category, mode: role.mode, options: role.options)
                if role == .recording { try? session.setAllowHapticsAndSystemSoundsDuringRecording(true) }
                try session.setActive(true, options: [])
                return nil
            } catch {
                return error
            }
        }, then: completion)
    }
}

/// The audio session's calls, one at a time, off the main thread for a
/// release.
///
/// - **A release waits its turn** on a serial queue; the caller goes on.
/// - **A claim cancels a release not begun** (a play right after a pause
///   keeps the session it has), and **waits for one under way**: it never
///   activates before a deactivation still in flight, which would leave the
///   session off under a playing message.
final class VoiceSessionLine: @unchecked Sendable {
    static let shared = VoiceSessionLine()

    private let queue = DispatchQueue(label: "VoiceKit.sessionLine", qos: .userInitiated)
    private let lock = NSLock()
    /// Every release and claim takes the next; a release runs only when it
    /// is still the last.
    private var ticket = 0

    func release(_ work: @escaping @Sendable () -> Void) {
        let mine = lock.withLock {
            ticket += 1
            return ticket
        }
        queue.async { [self] in
            guard lock.withLock({ ticket == mine }) else { return }
            work()
        }
    }

    func claim<T>(_ work: () throws -> T) rethrows -> T {
        cancelPendingReleases()
        return try queue.sync(execute: work)
    }

    /// A claim that doesn't wait (#2329): it cancels the releases not begun,
    /// runs on the line after one under way, and answers on the main thread.
    func claim(
        async work: @escaping @Sendable () -> (any Error)?,
        then done: @escaping @MainActor @Sendable ((any Error)?) -> Void
    ) {
        cancelPendingReleases()
        queue.async {
            let error = work()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { done(error) }
            }
        }
    }

    /// Every release queued and not begun will skip its work. One already
    /// running finishes: a claim then waits for it on the queue.
    func cancelPendingReleases() {
        lock.withLock { ticket += 1 }
    }
}

/// The two roles the session takes for voice (#2101).
public struct VoiceSessionRole: Equatable, Sendable {
    public let category: AVAudioSession.Category
    public let mode: AVAudioSession.Mode
    public let options: AVAudioSession.CategoryOptions

    /// Recording: play and record, the DEFAULT mode — not `.voiceChat`,
    /// whose voice processing is VoIP's — out of the speaker, and through a
    /// Bluetooth headset's microphone when one is connected.
    public static let recording = VoiceSessionRole(
        category: .playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP]
    )

    /// Listening: spoken audio that plays with the silent switch on, as
    /// WhatsApp and Telegram do.
    public static let listening = VoiceSessionRole(category: .playback, mode: .spokenAudio, options: [])

    @MainActor
    func apply(to session: any VoiceAudioSessionControlling) throws {
        try session.setCategory(category, mode: mode, options: options)
        // A take answers the finger with haptics — the start, the lock —
        // which iOS mutes while it records unless asked.
        if self == .recording { try? session.setAllowHapticsAndSystemSoundsDuringRecording(true) }
        try session.activate()
    }
}

/// While a voice message records or plays, everything else that makes sound
/// pauses — the feed's audible video, the sound sheet's track — and gets
/// the sound back when it ends (#2101). The voice engine POSTS these; the
/// players that must yield observe them, with no dependency on this package.
public enum VoiceAudioFocus {
    /// A take started recording, or a voice message started playing.
    public static let didTake = Notification.Name("VoiceAudioFocus.didTake")
    /// It ended, paused or was cancelled: the others may play again.
    public static let didRelease = Notification.Name("VoiceAudioFocus.didRelease")
}

/// The microphone permission (#2101): asked on the first recording attempt,
/// never before.
@MainActor
public protocol VoiceMicrophonePermission: AnyObject {
    var state: VoicePermissionState { get }
    /// Shows the system alert; true when granted.
    func request() async -> Bool
}

public enum VoicePermissionState: Equatable, Sendable {
    case undetermined, granted, denied
}

/// The system's answer, through `AVAudioApplication`.
@MainActor
public final class SystemMicrophonePermission: VoiceMicrophonePermission {
    public init() {}

    public var state: VoicePermissionState {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .undetermined
        }
    }

    public func request() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}

/// A repeating tick on the main actor — a `Timer` in the app, stepped by hand
/// in tests.
@MainActor
public protocol VoiceTicking: AnyObject {
    func start(interval: TimeInterval, _ tick: @escaping @MainActor () -> Void)
    func stop()
}

@MainActor
public final class TimerTicker: VoiceTicking {
    private var timer: Timer?

    public init() {}

    public func start(interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) {
        stop()
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }
}
