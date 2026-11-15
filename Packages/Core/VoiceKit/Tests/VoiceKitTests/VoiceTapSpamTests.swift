import AVFoundation
import Foundation
import Testing
@testable import VoiceKit

/// Fast play / pause taps (#2414, the owner's recording): the audio follows
/// the last tap, a voice already loaded is never loaded again, so its place
/// never moves back, and a pause keeps the session for a moment.
@MainActor
struct VoiceTapSpamTests {
    let center = NotificationCenter()
    let defaults: UserDefaults = {
        let name = "voice-tap-spam-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }()
    let a = URL(fileURLWithPath: "/tmp/a.m4a")
    let grace = ManualTicker()

    final class Box { var all: [FakeEngine] = [] }

    private func player(_ session: any VoiceAudioSessionControlling, _ engines: Box) -> VoicePlayer {
        VoicePlayer(session: session, makeEngine: {
            let engine = FakeEngine()
            engines.all.append(engine)
            return engine
        }, defaults: defaults, notifications: center, graceTimer: grace)
    }

    /// The bug: a tap while a resume waits on the session (`.loading`)
    /// went to play, and play from `.loading` made a new engine and loaded
    /// the file again — from an older place, or 0. Now that tap pauses it,
    /// the place kept, and the next one resumes the same engine.
    @Test func aTapWhileLoadingPausesAndKeepsThePlace() throws {
        let deferred = DeferredSession()
        let engines = Box()
        let player = player(deferred, engines)
        player.play("a", url: a)
        deferred.answer()
        let engine = try #require(engines.all.first)
        engine.currentTime = 4
        player.pause()
        grace.fire()

        player.toggle("a", url: a)
        #expect(player.state == .loading, "a resume after the grace waits on the session")
        player.toggle("a", url: a)
        #expect(player.state == .paused, "a tap while it loads didn't pause it")
        #expect(engines.all.count == 1, "a tap while it loads made a new engine")
        #expect(engine.seeks.isEmpty, "the place moved")
        #expect(player.progress == 0.4)

        player.toggle("a", url: a)
        deferred.answer()
        #expect(player.state == .playing)
        #expect(engines.all.count == 1 && engine.loaded == a, "the resume loaded the file again")
        #expect(engine.rates.count == 2)
        #expect(player.progress == 0.4, "the place moved back")
    }

    /// Twenty taps from a voice paused mid-way: it ends where one tap less
    /// or more would leave it — paused or playing at the same place — on
    /// the one engine.
    @Test func twentyTapsEndOnTheLastIntent() throws {
        let deferred = DeferredSession()
        let engines = Box()
        let player = player(deferred, engines)
        player.play("a", url: a)
        deferred.answer()
        let engine = try #require(engines.all.first)
        engine.currentTime = 6
        player.pause()
        grace.fire()
        for tap in 1...20 {
            player.toggle("a", url: a)
            // The session answers now and then, as it does.
            if tap % 3 == 0 { deferred.answer() }
            #expect(player.progress == 0.6, "tap \(tap): the place moved")
        }
        deferred.answer()
        #expect(player.state == .paused, "an even number of taps from paused ends paused")
        #expect(engines.all.count == 1)
        #expect(engine.seeks.isEmpty)
    }

    /// `play` on the voice already loaded — waiting on the session, paused
    /// or playing — goes on from where it is: no new engine, and the
    /// fraction (a place remembered at an older pause) is not read.
    @Test func aPlayOfTheVoiceLoadedNeverMakesANewEngine() throws {
        let deferred = DeferredSession()
        let engines = Box()
        let player = player(deferred, engines)
        player.play("a", url: a, from: 0.5)
        #expect(player.state == .loading)
        player.play("a", url: a, from: 0.1)
        #expect(engines.all.count == 1, "loading: a new engine")
        let engine = try #require(engines.all.first)
        #expect(engine.seeks == [5], "loading: it went to an older place")
        deferred.answer()
        player.play("a", url: a, from: 0.1)
        #expect(engines.all.count == 1 && engine.seeks == [5], "playing: a new engine, or a seek")
    }

    /// A pause keeps the session and the focus for `releaseGrace`: a resume
    /// inside it plays at once, with no activation; past it the session
    /// goes back and the others get the sound back.
    @Test func aPauseKeepsTheSessionForTheGrace() {
        let session = FakeSession()
        let player = player(session, Box())
        let focus = NameLog()
        let observers = [VoiceAudioFocus.didTake, VoiceAudioFocus.didRelease].map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { focus.names.append($0.name) }
        }
        defer { observers.forEach(center.removeObserver) }

        player.play("a", url: a)
        let taken = session.activations.count
        player.pause()
        #expect(session.activations.allSatisfy { $0.0 }, "the pause gave the session back at once")
        #expect(focus.names == [VoiceAudioFocus.didTake], "the others got the sound back at once")
        #expect(player.releasePending && grace.isRunning && grace.interval == VoicePlayer.releaseGrace)

        player.play("a", url: a)
        #expect(player.state == .playing, "a resume inside the grace waited")
        #expect(session.activations.count == taken, "a resume inside the grace took the session again")
        #expect(!player.releasePending && !grace.isRunning)

        player.pause()
        grace.fire()
        #expect(session.activations.last?.0 == false, "past the grace the session stayed")
        #expect(focus.names == [VoiceAudioFocus.didTake, VoiceAudioFocus.didRelease])
        #expect(!player.releasePending)

        player.play("a", url: a)
        #expect(session.activations.count > taken + 1, "a resume past the grace didn't take the session")
        #expect(player.state == .playing)
    }

    /// A call, Siri or an alarm, headphones out, another take, the
    /// background: released at once — a grace under way included.
    @Test func whatTheSystemAsksIsReleasedAtOnce() {
        let session = FakeSession()
        let player = player(session, Box())

        // A call while it plays.
        player.play("a", url: a)
        center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
        ])
        #expect(player.state == .paused && !player.releasePending)
        #expect(session.activations.last?.0 == false, "a call waited out the grace")

        // A call during a pause's grace.
        player.play("a", url: a)
        player.pause()
        #expect(player.releasePending)
        center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
        ])
        #expect(!player.releasePending && !grace.isRunning)
        #expect(session.activations.last?.0 == false, "the grace kept the session through a call")

        // Headphones out.
        player.play("a", url: a)
        center.post(name: AVAudioSession.routeChangeNotification, object: nil, userInfo: [
            AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
        ])
        #expect(player.state == .paused && !player.releasePending)

        // Another take during the grace: it needs the session now.
        player.play("a", url: a)
        player.pause()
        center.post(name: VoiceAudioFocus.didTake, object: NSObject())
        #expect(!player.releasePending)
        #expect(session.activations.last?.0 == false)

        // Sent to the background.
        player.play("a", url: a)
        player.pause(releaseAtOnce: true)
        #expect(!player.releasePending && session.activations.last?.0 == false)
    }
}
