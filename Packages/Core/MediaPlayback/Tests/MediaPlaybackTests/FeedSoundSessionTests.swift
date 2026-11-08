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
        // The key's own read (#2185), then the tick's.
        #expect(probe.ringerChecks == 2)
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

    /// ⚠️ ON A RINGING PHONE THE KEY CHANGES NO CATEGORY (#2185): the
    /// `.ambient` session is already heard, and switching it under the
    /// playing clip cut its sound and hitched its picture. The sound is on in
    /// the state only; ring → silent still turns it off.
    @Test func onARingingPhoneTheKeyKeepsTheAmbientSession() {
        let probe = Probe()
        let sound = session(probe)
        let controller = VideoPlaybackController(source: Passthrough(), poolSize: 1, capacity: 1)
        controller.feedSound = sound
        defer { resetToLaunch(sound, controller) }
        #expect(AVAudioSession.sharedInstance().category == .ambient)
        sound.setWatching(true, by: controller)
        sound.volumeDidChange()
        #expect(sound.isTurnedOn && sound.isHeard)
        #expect(probe.ringerChecks == 1, "the ringer was not read at the key")
        #expect(!sound.playsThroughSilentSwitch)
        #expect(AVAudioSession.sharedInstance().category == .ambient, "the category changed under the clip")
        probe.silent = true
        sound.checkRinger()
        #expect(!sound.isTurnedOn, "ring → silent kept the sound on")
        #expect(AVAudioSession.sharedInstance().category == .ambient)
    }

    /// On a silent phone nothing was heard before the key: the session
    /// switches to `.playback` there, heard through the switch, and goes back
    /// to `.ambient` once the sound is off.
    @Test func onASilentPhoneTheKeyPlaysThroughTheSwitch() {
        let probe = Probe()
        probe.silent = true
        let sound = session(probe)
        let controller = VideoPlaybackController(source: Passthrough(), poolSize: 1, capacity: 1)
        controller.feedSound = sound
        defer { resetToLaunch(sound, controller) }
        let announced = Counter()
        let token = NotificationCenter.default.addObserver(
            forName: FeedSoundSession.didNeedPlayThrough, object: sound, queue: nil
        ) { _ in announced.add() }
        defer { NotificationCenter.default.removeObserver(token) }
        sound.setWatching(true, by: controller)
        sound.volumeDidChange()
        #expect(sound.playsThroughSilentSwitch)
        #expect(announced.value == 1)
        #expect(AVAudioSession.sharedInstance().category == .playback)
        // Already silent: the checks reading silent keep it on.
        sound.checkRinger()
        #expect(sound.isTurnedOn)
        probe.silent = false
        sound.checkRinger()
        probe.silent = true
        sound.checkRinger()
        #expect(!sound.isTurnedOn && !sound.playsThroughSilentSwitch)
        #expect(AVAudioSession.sharedInstance().category == .ambient, "on silent again, still heard through it")
    }

    /// A check that never answers leaves the session `.ambient` — towards
    /// silence — and a late answer for a sound already off is dropped.
    @Test func aKeyReadThatNeverAnswersKeepsAmbient() {
        let probe = Probe()
        nonisolated(unsafe) var pending: [(Bool) -> Void] = []
        let sound = FeedSoundSession(
            otherAudioPlaying: { false },
            observe: { _ in NSObject() },
            probeSilent: { done in
                probe.ringerChecks += 1
                pending.append { done($0) }
            },
            tick: { _ in NSObject() }
        )
        let controller = VideoPlaybackController(source: Passthrough(), poolSize: 1, capacity: 1)
        controller.feedSound = sound
        defer { resetToLaunch(sound, controller) }
        sound.setWatching(true, by: controller)
        sound.volumeDidChange()
        #expect(sound.isTurnedOn && !sound.playsThroughSilentSwitch)
        #expect(AVAudioSession.sharedInstance().category == .ambient)
        // The sound goes off before the key's read lands: it is dropped.
        sound.debugReset()
        pending.first?(true)
        #expect(!sound.playsThroughSilentSwitch)
        #expect(AVAudioSession.sharedInstance().category == .ambient)
    }

    /// Back to a fresh launch for the next suite.
    private func resetToLaunch(_ sound: FeedSoundSession, _ controller: VideoPlaybackController) {
        sound.debugReset()
        controller.feedSound = FeedSoundSession(otherAudioPlaying: { false }, observe: { _ in nil }, tick: { _ in nil })
        #expect(AVAudioSession.sharedInstance().category == .ambient)
    }

    // MARK: - Heard before any key (#483)

    /// Counts announcements; posted synchronously on this thread.
    private final class Counter: @unchecked Sendable {
        private(set) var value = 0
        func add() { value += 1 }
    }

    /// A ringing phone hears the `.ambient` feed before any volume key, so
    /// Background Play and Picture in Picture may keep it: the ringer is read
    /// for a screen that asks (`readsRinger`), at once and then each tick.
    @Test func aRingingPhoneHearsTheFeedBeforeAnyKey() {
        let probe = Probe()
        let sound = session(probe)
        let feed = NSObject()
        sound.setWatching(true, by: feed, readsRinger: true)
        #expect(probe.ringerChecks == 1, "read at once: the app may leave before the first tick")
        #expect(sound.isCheckingRinger)
        #expect(!sound.isTurnedOn)
        #expect(sound.isHeard)
    }

    /// On silent, nothing is heard: `.playback` would make the feed heard for
    /// the first time through the switch.
    @Test func aSilentPhoneDoesNotHearTheFeed() {
        let probe = Probe()
        probe.silent = true
        let sound = session(probe)
        sound.setWatching(true, by: NSObject(), readsRinger: true)
        #expect(!sound.isHeard)
    }

    /// The switch moving while the sound follows the device is announced, so
    /// a readied floating window lets go.
    @Test func theSwitchMovingIsAnnounced() {
        let probe = Probe()
        let sound = session(probe)
        let feed = NSObject()
        let announced = Counter()
        let token = NotificationCenter.default.addObserver(
            forName: FeedSoundSession.audibilityDidChange, object: sound, queue: nil
        ) { _ in announced.add() }
        defer { NotificationCenter.default.removeObserver(token) }
        sound.setWatching(true, by: feed, readsRinger: true)
        #expect(announced.value == 1 && sound.isHeard)
        probe.silent = true
        sound.checkRinger()
        #expect(announced.value == 2 && !sound.isHeard)
        sound.checkRinger()
        #expect(announced.value == 2, "no change, no announcement")
    }

    /// Never over another app's audio: `.playback` would stop it.
    @Test func anotherAppsAudioIsNeverInterrupted() {
        let probe = Probe()
        let sound = session(probe)
        sound.setWatching(true, by: NSObject(), readsRinger: true)
        probe.otherAudio = true
        #expect(!sound.isHeard)
    }

    /// No screen asking (both settings off): the ringer is not read before a
    /// key, as before #483.
    @Test func theRingerIsReadOnlyForAScreenThatAsks() {
        let probe = Probe()
        let sound = session(probe)
        sound.setWatching(true, by: NSObject())
        #expect(probe.ringerChecks == 0)
        #expect(!sound.isCheckingRinger)
        #expect(!sound.isHeard)
    }
}
