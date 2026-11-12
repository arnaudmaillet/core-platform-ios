import AVFoundation
import Foundation
import Testing
@testable import VoiceKit

/// The one voice player (#2101), over a fake engine and session.
@MainActor
struct VoicePlayerTests {
    let session = FakeSession()
    let center = NotificationCenter()
    let defaults: UserDefaults = {
        let name = "voice-player-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }()
    let a = URL(fileURLWithPath: "/tmp/a.m4a")
    let b = URL(fileURLWithPath: "/tmp/b.m4a")

    func player(_ engines: Box) -> VoicePlayer {
        VoicePlayer(session: session, makeEngine: {
            let engine = FakeEngine()
            engines.all.append(engine)
            return engine
        }, defaults: defaults, notifications: center)
    }

    final class Box { var all: [FakeEngine] = [] }

    /// Starting one message stops the one playing.
    @Test func oneMessageAtATime() {
        let engines = Box()
        let player = player(engines)
        player.play("a", url: a)
        #expect(player.state == .playing)
        player.play("b", url: b)
        #expect(player.messageID == "b")
        #expect(engines.all.count == 2)
        #expect(engines.all[0].pauses >= 1, "the first message kept playing")
        #expect(engines.all[1].loaded == b)
    }

    /// Paused, the same message resumes where it was.
    @Test func theSameMessageResumes() {
        let engines = Box()
        let player = player(engines)
        player.play("a", url: a)
        player.pause()
        #expect(player.state == .paused)
        player.play("a", url: a)
        #expect(player.state == .playing)
        #expect(engines.all.count == 1, "a resume reloaded the file")
    }

    /// ⚠️ The session is taken off the main thread (#2329): a play stays
    /// loading until it is, and only then plays; a pause or another message
    /// meanwhile, and the late answer plays nothing; a resume waits loading
    /// too.
    @Test func aPlayWaitsForTheSessionWithoutHoldingTheMainThread() {
        let deferred = DeferredSession()
        let engines = Box()
        let player = VoicePlayer(session: deferred, makeEngine: {
            let engine = FakeEngine()
            engines.all.append(engine)
            return engine
        }, defaults: defaults, notifications: center)
        player.play("a", url: a)
        #expect(player.state == .loading, "it played before the session was taken")
        #expect(engines.all[0].rates.isEmpty)
        deferred.answer()
        #expect(player.state == .playing && engines.all[0].rates.count == 1)

        // Paused while the session is being taken: the answer plays nothing.
        player.pause()
        player.play("a", url: a)
        #expect(player.state == .loading, "a resume waiting on the session says so")
        player.pause()
        deferred.answer()
        #expect(player.state == .paused && engines.all[0].rates.count == 1, "a late answer played a paused voice")

        // Another message started meanwhile: only its own answer plays it.
        player.play("a", url: a)
        player.play("b", url: b)
        deferred.answer()
        #expect(player.messageID == "b" && player.state == .playing)
        #expect(engines.all[0].rates.count == 1, "the first message played after the second started")

        // A session that can't be taken fails the play.
        player.play("a", url: a)
        deferred.answer(CocoaError(.featureUnsupported))
        #expect(player.state == .failed)
    }

    /// The speed is applied to what plays, kept across launches, pitch kept.
    @Test func theSpeedIsAppliedAndKept() {
        let engines = Box()
        let player = player(engines)
        player.play("a", url: a)
        player.setSpeed(.faster)
        #expect(engines.all[0].rates == [1, 2])
        #expect(self.player(Box()).speed == .faster, "the speed was forgotten")
        player.play("b", url: b)
        #expect(engines.all[1].rates == [2])
        #expect(VoicePlaybackSpeed.normal.next == .fast && VoicePlaybackSpeed.faster.next == .normal)
    }

    /// Headphones out, or a call: it pauses, and nothing resumes on its own.
    @Test func aRouteChangeOrACallPauses() {
        let engines = Box()
        let player = player(engines)
        player.play("a", url: a)
        center.post(name: AVAudioSession.routeChangeNotification, object: nil, userInfo: [
            AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
        ])
        #expect(player.state == .paused)
        player.play("a", url: a)
        center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
        ])
        #expect(player.state == .paused)
        center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
        ])
        #expect(player.state == .paused, "it resumed on its own")
    }

    /// Listening: spoken audio through the silent switch; the others pause
    /// while it plays and get the sound back at the end.
    @Test func theSessionIsTheListeningRoleAndTheOthersYield() {
        let engines = Box()
        let player = player(engines)
        let focus = NameLog()
        let observers = [VoiceAudioFocus.didTake, VoiceAudioFocus.didRelease].map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { focus.names.append($0.name) }
        }
        defer { observers.forEach(center.removeObserver) }
        player.play("a", url: a)
        #expect(session.roles == [.listening])
        #expect(VoiceSessionRole.listening.category == .playback)
        #expect(VoiceSessionRole.listening.mode == .spokenAudio)
        engines.all[0].onEnd?()
        #expect(player.state == .ended)
        #expect(focus.names == [VoiceAudioFocus.didTake, VoiceAudioFocus.didRelease])
        #expect(session.activations.last?.0 == false)
    }

    /// A take starting pauses the message playing.
    @Test func aTakeStartingPausesTheMessage() {
        let player = player(Box())
        player.play("a", url: a)
        center.post(name: VoiceAudioFocus.didTake, object: NSObject())
        #expect(player.state == .paused)
    }

    /// A message come back to mid-way starts where it was left — once the
    /// file says its length.
    @Test func aSeekBeforeTheLengthIsKnownWaitsForIt() {
        let engines = Box()
        let player = VoicePlayer(session: session, makeEngine: {
            let engine = FakeEngine()
            engine.duration = nil
            engines.all.append(engine)
            return engine
        }, defaults: defaults, notifications: center)
        player.play("a", url: a, from: 0.5)
        #expect(engines.all[0].seeks.isEmpty)
        engines.all[0].duration = 8
        player.tick()
        #expect(engines.all[0].seeks == [4])
        player.tick()
        #expect(engines.all[0].seeks == [4], "the waiting seek ran twice")
    }

    @Test func seekMovesWithinTheLength() {
        let engines = Box()
        let player = player(engines)
        player.play("a", url: a)
        player.seek(to: 0.25)
        player.seek(to: 2)
        #expect(engines.all[0].seeks == [2.5, 10])
    }
}
