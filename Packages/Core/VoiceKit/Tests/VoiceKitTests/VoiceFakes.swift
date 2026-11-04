import AVFoundation
import Foundation
@testable import VoiceKit

@MainActor
final class FakeSession: VoiceAudioSessionControlling {
    var roles: [VoiceSessionRole] = []
    var activations: [(Bool, AVAudioSession.SetActiveOptions)] = []
    var isInputAvailable = true

    func setCategory(
        _ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions
    ) throws {
        roles.append(VoiceSessionRole(category: category, mode: mode, options: options))
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        activations.append((active, options))
    }
}

@MainActor
final class FakePermission: VoiceMicrophonePermission {
    var state: VoicePermissionState
    var answer = true
    var requests = 0

    init(_ state: VoicePermissionState) { self.state = state }

    func request() async -> Bool {
        requests += 1
        state = answer ? .granted : .denied
        return answer
    }
}

/// A recorder whose clock and meter the test sets; it writes a real (empty)
/// file so deletion can be checked.
@MainActor
final class FakeDevice: VoiceRecordingDevice {
    var currentTime: TimeInterval = 0
    var power: (average: Float, peak: Float) = (-20, -10)
    private(set) var url: URL?
    private(set) var records = 0
    private(set) var pauses = 0
    private(set) var stops = 0

    func prepare(writingTo url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: Data([0]))
    }

    func record() -> Bool {
        records += 1
        return true
    }

    func pause() { pauses += 1 }
    func stop() { stops += 1 }
    func meter() -> (average: Float, peak: Float) { power }
}

@MainActor
final class ManualTicker: VoiceTicking {
    private var tick: (@MainActor () -> Void)?
    private(set) var interval: TimeInterval?
    var isRunning: Bool { tick != nil }

    func start(interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.tick = tick
    }

    func stop() { tick = nil }

    func fire(_ times: Int = 1) {
        for _ in 0..<times { tick?() }
    }
}

@MainActor
final class FakeEngine: VoicePlaybackEngine {
    var onEnd: (() -> Void)?
    var onFailure: (() -> Void)?
    var currentTime: TimeInterval = 0
    var duration: TimeInterval? = 10
    private(set) var loaded: URL?
    private(set) var rates: [Float] = []
    private(set) var pauses = 0
    private(set) var seeks: [TimeInterval] = []

    func load(_ url: URL) { loaded = url }
    func play(rate: Float) { rates.append(rate) }
    func pause() { pauses += 1 }
    func seek(to seconds: TimeInterval) { seeks.append(seconds) }
}

/// Notifications heard, in order — written from the poster's thread (the
/// test's own, which posts them).
final class NameLog: @unchecked Sendable {
    var names: [Notification.Name] = []
}
