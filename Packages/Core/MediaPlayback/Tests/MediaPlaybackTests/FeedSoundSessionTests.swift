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
    }

    private func session(_ probe: Probe) -> FeedSoundSession {
        FeedSoundSession(
            otherAudioPlaying: { probe.otherAudio },
            observe: { _ in
                probe.observing += 1
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

    /// The pool's session: `.ambient` at launch, `.playback` once the sound
    /// is on — heard through the silent switch.
    @Test func theSessionPlaysThroughTheSwitchOnceTheSoundIsOn() {
        let probe = Probe()
        let sound = session(probe)
        let controller = VideoPlaybackController(source: Passthrough(), poolSize: 1, capacity: 1)
        controller.feedSound = sound
        #expect(AVAudioSession.sharedInstance().category == .ambient)
        sound.setWatching(true, by: controller)
        sound.volumeDidChange()
        #expect(AVAudioSession.sharedInstance().category == .playback)
        // Back to a fresh launch for the next suite.
        sound.debugReset()
        controller.feedSound = FeedSoundSession(otherAudioPlaying: { false }, observe: { _ in nil })
        #expect(AVAudioSession.sharedInstance().category == .ambient)
    }
}
