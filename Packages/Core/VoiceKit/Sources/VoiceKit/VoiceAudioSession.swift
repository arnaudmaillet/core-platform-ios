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
}

extension AVAudioSession: VoiceAudioSessionControlling {}

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
        try session.setActive(true, options: [])
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
