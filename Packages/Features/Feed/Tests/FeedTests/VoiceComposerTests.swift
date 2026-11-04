import AVFoundation
import FeedInterface
import Testing
import UIKit
import VoiceKit
@testable import Feed

/// Recording from the composer (#2102), over #2101's recorder with a fake
/// device: no microphone.
@MainActor
struct VoiceComposerTests {
    final class Session: VoiceAudioSessionControlling {
        var isInputAvailable = true
        func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws {}
        func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {}
    }

    final class Permission: VoiceMicrophonePermission {
        var state: VoicePermissionState
        init(_ state: VoicePermissionState) { self.state = state }
        func request() async -> Bool { state = .granted; return true }
    }

    final class Device: VoiceRecordingDevice {
        var currentTime: TimeInterval = 0
        private(set) var pauses = 0
        func prepare(writingTo url: URL) throws {
            FileManager.default.createFile(atPath: url.path, contents: Data([0]))
        }
        func record() -> Bool { true }
        func pause() { pauses += 1 }
        func stop() {}
        func meter() -> (average: Float, peak: Float) { (-20, -10) }
    }

    final class Ticker: VoiceTicking {
        func start(interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) {}
        func stop() {}
    }

    final class Clock {
        var now = Date(timeIntervalSince1970: 0)
    }

    let device = Device()
    let clock = Clock()

    func composer(_ permission: VoicePermissionState = .granted, key: String = "conv-\(UUID().uuidString)")
        -> (VoiceComposer, CommentsInputBar, Sent) {
        let fake = device
        let recorder = VoiceRecorder(
            session: Session(), permission: Permission(permission), makeDevice: { fake }, ticker: Ticker(),
            notifications: NotificationCenter(), keepAwake: { _ in }
        )
        let time = clock
        let composer = VoiceComposer(recorder: recorder, draftKey: key, now: { time.now })
        let bar = CommentsInputBar()
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        host.addSubview(bar)
        composer.attach(to: bar, host: host)
        let sent = Sent()
        composer.onSend = { sent.takes.append($0) }
        composer.onHint = { sent.hints.append($0) }
        composer.onPermissionDenied = { sent.denied += 1 }
        return (composer, bar, sent)
    }

    final class Sent {
        var takes: [ConversationThreadVoiceTake] = []
        var hints: [String] = []
        var denied = 0
    }

    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Hold, wait past 200 ms, release: sent.
    @Test func holdThenReleaseSends() async {
        let (composer, bar, sent) = composer()
        #expect(bar.holdsToRecord)
        composer.handle(.began)
        #expect(await settle { composer.phase == .holding(revealed: true) }, "the strip never showed")
        #expect(bar.voiceOverlay === composer.debugStrip)
        device.currentTime = 3
        clock.now += 3
        composer.handle(.ended(leading: 0))
        #expect(sent.takes.count == 1)
        #expect(sent.takes.first?.duration == 3)
        #expect(composer.phase == .idle)
        #expect(bar.voiceOverlay == nil, "the field was not given back")
    }

    /// A quick lift is a tap: the hint, nothing recorded or sent.
    @Test func aTapShowsTheHint() async {
        let (composer, _, sent) = composer()
        composer.handle(.began)
        clock.now += 0.1
        composer.handle(.ended(leading: 0))
        #expect(await settle { sent.hints == [VoiceComposer.hint] })
        #expect(sent.takes.isEmpty)
        #expect(composer.phase == .idle)
    }

    /// Held, but under a second of sound: refused, with the hint.
    @Test func underASecondIsNotSent() async {
        let (composer, _, sent) = composer()
        composer.handle(.began)
        #expect(await settle { composer.phase == .holding(revealed: true) })
        device.currentTime = 0.6
        clock.now += 0.6
        composer.handle(.ended(leading: 0))
        #expect(sent.takes.isEmpty)
        #expect(sent.hints == [VoiceComposer.hint])
    }

    /// Slid 100 pt toward the leading edge: cancelled, nothing sent.
    @Test func slidingAwayCancels() async {
        let (composer, _, sent) = composer()
        composer.handle(.began)
        #expect(await settle { composer.phase == .holding(revealed: true) })
        device.currentTime = 4
        composer.handle(.moved(leading: 100, up: 0))
        #expect(composer.phase == .idle)
        composer.handle(.ended(leading: 100))
        #expect(sent.takes.isEmpty)
    }

    /// Slid up past the lock: the finger is free; pause, then ↑ sends once.
    @Test func lockPauseThenSend() async {
        let (composer, bar, sent) = composer()
        composer.handle(.began)
        #expect(await settle { composer.phase == .holding(revealed: true) })
        composer.handle(.moved(leading: 0, up: 101))
        #expect(composer.phase == .locked)
        composer.handle(.ended(leading: 0))
        #expect(composer.phase == .locked, "lifting the finger after the lock ended the take")
        #expect(composer.debugStrip.debugVisibleControls == ["Delete recording", "Pause recording", "Send voice message"])
        composer.debugStrip.debugTap("Pause recording")
        #expect(composer.phase == .paused(resumable: true))
        #expect(device.pauses == 1)
        #expect(composer.debugStrip.debugVisibleControls.contains("Resume recording"))
        device.currentTime = 7
        composer.debugStrip.debugTap("Send voice message")
        #expect(sent.takes.count == 1)
        #expect(bar.voiceOverlay == nil)
    }

    /// Refused before: a hold offers Settings, and records nothing.
    @Test func aDeniedMicrophoneOffersSettings() async {
        let (composer, _, sent) = composer(.denied)
        composer.handle(.began)
        #expect(await settle { sent.denied == 1 })
        #expect(composer.phase == .idle)
    }

    /// A locked take left behind is the conversation's draft for the app's
    /// session: coming back shows the paused bar.
    @Test func aLockedTakeIsKeptAsTheConversationsDraft() async {
        let key = "conv-draft-\(UUID().uuidString)"
        let (composer, _, _) = composer(key: key)
        composer.handle(.began)
        #expect(await settle { composer.phase == .holding(revealed: true) })
        composer.handle(.moved(leading: 0, up: 101))
        device.currentTime = 5
        composer.leave()
        #expect(VoiceComposer.debugDraft(for: key)?.duration == 5)
        let (again, bar, _) = self.composer(key: key)
        #expect(again.phase == .paused(resumable: false))
        #expect(bar.voiceOverlay != nil)
        #expect(VoiceComposer.debugDraft(for: key) == nil, "the draft was shown and kept")
    }

    /// A post's comments keep today's tap: no hold.
    @Test func aPostsComposerKeepsTheTap() {
        let bar = CommentsInputBar()
        #expect(!bar.holdsToRecord)
    }
}
