import AVFoundation
import Testing
import UIKit
@testable import MediaPlayback

/// The feed's sound (#1931): it follows the device until the viewer presses a
/// volume key while a feed plays; then it is heard for the session — never
/// over another app's audio, and never with no feed watching.
@MainActor
@Suite(.serialized, .exclusiveMediaWork)
struct FeedSoundSessionTests {
    private struct Passthrough: VideoSource {
        func playableURL(for url: URL) async throws -> URL { url }
    }

    /// A session whose volume observation is the test's: `observing` counts
    /// the watches started, and a key is `volumeDidChange()`.
    private final class Probe {
        var otherAudio = false
        var observing = 0
        /// What the ringer check answers: silent or not.
        var silent = false
        var ringerChecks = 0
        var ticking = 0
    }

    private func session(_ probe: Probe) -> FeedSoundSession {
        FeedSoundSession(
            otherAudioPlaying: { probe.otherAudio },
            observe: { _ in
                probe.observing += 1
                return NSObject()
            },
            probeSilent: { done in
                probe.ringerChecks += 1
                done(probe.silent)
            },
            tick: { _ in
                probe.ticking += 1
                return NSObject()
            }
        )
    }

    @Test func aVolumeKeyWithAFeedWatchingTurnsTheSoundOnForTheSession() {
        let probe = Probe()
        let sound = session(probe)
        let feed = NSObject()
        #expect(!sound.isTurnedOn, "the feed starts following the device")
        sound.setWatching(true, by: feed)
        #expect(probe.observing == 1, "a feed on screen does not listen for a key")
        sound.volumeDidChange()
        #expect(sound.isTurnedOn)
        // For the session: the feed leaving and coming back keeps it.
        sound.setWatching(false, by: feed)
        sound.setWatching(true, by: feed)
        #expect(sound.isTurnedOn)
        #expect(probe.observing == 1, "it keeps listening once the sound is on")
    }

    /// With music from another app, a key is about that music: the feed
    /// stays mixed and silent.
    @Test func aVolumeKeyOverAnotherAppsAudioChangesNothing() {
        let probe = Probe()
        probe.otherAudio = true
        let sound = session(probe)
        sound.setWatching(true, by: NSObject())
        sound.volumeDidChange()
        #expect(!sound.isTurnedOn)
    }

    /// One feed leaving under another that arrived does not stop the
    /// other's watch; the last one leaving does.
    @Test func theWatchIsPerFeed() {
        let probe = Probe()
        let sound = session(probe)
        let under = NSObject(), over = NSObject()
        sound.setWatching(true, by: under)
        sound.setWatching(true, by: over)
        sound.setWatching(false, by: under)
        sound.setWatching(true, by: over)
        #expect(probe.observing == 1)
        sound.setWatching(false, by: over)
        sound.setWatching(true, by: over)
        #expect(probe.observing == 2, "the last feed leaving did not stop the watch")
    }

    /// ⚠️ PUT ON SILENT AGAIN, THE SOUND GOES OFF (the owner, 2026-10-30, as
    /// Instagram does): the ringer is checked only while the sound is on and
    /// a feed plays, and a silent answer turns it off — the next volume key
    /// turns it on again.
    @Test func theSilentSwitchTurnsTheSoundOffAgain() {
        let probe = Probe()
        let sound = session(probe)
        let feed = NSObject()
        sound.setWatching(true, by: feed)
        #expect(!sound.isCheckingRinger, "the ringer is checked before the sound is on")
        sound.volumeDidChange()
        #expect(sound.isCheckingRinger)
        #expect(probe.ticking == 1)

        sound.checkRinger()
        #expect(sound.isTurnedOn, "a ringing phone turned the sound off")
        #expect(probe.ringerChecks == 1)
        nonisolated(unsafe) var told = false
        let token = NotificationCenter.default.addObserver(
            forName: FeedSoundSession.didTurnOff, object: sound, queue: nil
        ) { _ in told = true }
        defer { NotificationCenter.default.removeObserver(token) }
        probe.silent = true
        sound.checkRinger()
        #expect(!sound.isTurnedOn, "the silent switch left the sound on")
        #expect(told)
        #expect(!sound.isCheckingRinger)
        #expect(probe.observing == 2, "the next volume key goes unheard")
        sound.volumeDidChange()
        #expect(sound.isTurnedOn)
    }

    /// ⚠️ ON A PHONE ALREADY SILENT, A VOLUME KEY KEEPS THE SOUND (the
    /// reviewer's catch): the checks read "silent" from the start, which is
    /// no change — only ring → silent turns it off.
    @Test func aPhoneAlreadySilentKeepsTheSoundAKeyTurnedOn() {
        let probe = Probe()
        probe.silent = true
        let sound = session(probe)
        sound.setWatching(true, by: NSObject())
        sound.volumeDidChange()
        sound.checkRinger()
        sound.checkRinger()
        #expect(sound.isTurnedOn, "the switch already on silent turned the sound off")
        probe.silent = false
        sound.checkRinger()
        probe.silent = true
        sound.checkRinger()
        #expect(!sound.isTurnedOn, "ring → silent kept the sound on")
    }

    /// No feed playing, no ringer check.
    @Test func theRingerIsCheckedOnlyWhileAFeedPlays() {
        let probe = Probe()
        let sound = session(probe)
        let feed = NSObject()
        sound.setWatching(true, by: feed)
        sound.volumeDidChange()
        sound.setWatching(false, by: feed)
        #expect(!sound.isCheckingRinger)
        sound.setWatching(true, by: feed)
        #expect(sound.isCheckingRinger)
        #expect(probe.ticking == 2)
    }

    /// The pool's session: `.ambient` at launch, `.playback` once the sound
    /// is on — heard through the silent switch — and `.ambient` again once
    /// the phone is put on silent.
    @Test func theSessionPlaysThroughTheSwitchOnceTheSoundIsOn() {
        let probe = Probe()
        let sound = session(probe)
        let controller = VideoPlaybackController(source: Passthrough(), poolSize: 1, capacity: 1)
        controller.feedSound = sound
        #expect(AVAudioSession.sharedInstance().category == .ambient)
        sound.setWatching(true, by: controller)
        sound.volumeDidChange()
        #expect(AVAudioSession.sharedInstance().category == .playback)
        sound.checkRinger()
        probe.silent = true
        sound.checkRinger()
        #expect(AVAudioSession.sharedInstance().category == .ambient, "on silent again, still heard through it")
        // Back to a fresh launch for the next suite.
        sound.debugReset()
        controller.feedSound = FeedSoundSession(otherAudioPlaying: { false }, observe: { _ in nil }, tick: { _ in nil })
        #expect(AVAudioSession.sharedInstance().category == .ambient)
    }
}
