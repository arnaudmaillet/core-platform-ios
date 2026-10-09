import CoreStorage
import Foundation
import MediaPlayback
import Testing
@testable import Feed

/// Playback preferences (#409) and how the feed reads them against the
/// network: autoplay, preloading, stream quality, and where the session's
/// sound starts.
@MainActor
@Suite(.serialized)
struct MediaPlaybackPolicyTests {
    private func store(_ mutate: (inout MediaPlaybackPreferences) -> Void = { _ in }) -> MediaPlaybackPreferencesStore {
        let store = MediaPlaybackPreferencesStore(defaults: UserDefaults(suiteName: "playback-\(UUID().uuidString)")!)
        store.update(mutate)
        return store
    }

    @Test func autoplayFollowsTheChoiceAndTheNetwork() {
        let always = MediaPlaybackPreferences(autoplay: .always)
        let wifi = MediaPlaybackPreferences(autoplay: .wifiOnly)
        let never = MediaPlaybackPreferences(autoplay: .never)
        #expect(always.autoplays(onCellular: true))
        #expect(wifi.autoplays(onCellular: false))
        #expect(!wifi.autoplays(onCellular: true))
        #expect(!never.autoplays(onCellular: false))
    }

    @Test func dataSaverOnlyBitesOnCellular() {
        let saver = MediaPlaybackPreferences(dataSaver: true)
        #expect(!saver.preloads(onCellular: true))
        #expect(saver.preloads(onCellular: false))
        #expect(saver.peakBitRate(onCellular: true) == MediaPlaybackPreferences.dataSaverPeakBitRate)
        #expect(saver.peakBitRate(onCellular: false) == 0)
        #expect(MediaPlaybackPreferences().peakBitRate(onCellular: true) == 0)
    }

    /// Background Play (#483) is off unless turned on, and preferences saved
    /// before it existed keep everything they held.
    @Test func backgroundPlayIsOffByDefaultAndOldPreferencesStillRead() throws {
        #expect(!MediaPlaybackPreferences().backgroundPlay)
        let defaults = UserDefaults(suiteName: "playback-\(UUID().uuidString)")!
        let saved = #"{"autoplay":"never","startsWithSound":false,"dataSaver":true}"#
        defaults.set(Data(saved.utf8), forKey: "mediaPlaybackPreferences")
        let store = MediaPlaybackPreferencesStore(defaults: defaults)
        #expect(store.preferences == MediaPlaybackPreferences(autoplay: .never, startsWithSound: false, dataSaver: true))

        store.update { $0.backgroundPlay = true }
        #expect(MediaPlaybackPreferencesStore(defaults: defaults).preferences.backgroundPlay)
        #expect(MediaPlaybackPreferencesStore(defaults: defaults).preferences.autoplay == .never)

        let previousStore = MediaPlaybackPolicy.store
        defer { MediaPlaybackPolicy.store = previousStore }
        MediaPlaybackPolicy.store = store
        #expect(MediaPlaybackPolicy.playsInBackground)

        // Picture in Picture: off by default too, and its own switch.
        #expect(!MediaPlaybackPreferences().pictureInPicture)
        #expect(!MediaPlaybackPolicy.floatsInPictureInPicture)
        store.update { $0.pictureInPicture = true }
        #expect(MediaPlaybackPolicy.floatsInPictureInPicture)
        #expect(MediaPlaybackPolicy.playsInBackground, "one switch leaves the other alone")
    }

    /// The player pool (#702): Normal by default — preferences saved before
    /// it existed read Normal — and the notches grow in that order.
    @Test func thePlayerPoolDefaultsToNormalAndOldPreferencesStillRead() throws {
        #expect(MediaPlaybackPreferences().playerPool == .normal)
        let sizes = MediaPlaybackPreferences.PlayerPool.allCases.map(\.size)
        #expect(sizes == sizes.sorted() && Set(sizes).count == sizes.count, "the notches do not grow: \(sizes)")
        #expect(MediaPlaybackPreferences.PlayerPool.normal.size == 6, "Normal is the pools' long-standing size")

        let defaults = UserDefaults(suiteName: "playback-pool-\(UUID().uuidString)")!
        defaults.set(Data(#"{"autoplay":"always","startsWithSound":true,"dataSaver":false}"#.utf8), forKey: "mediaPlaybackPreferences")
        let store = MediaPlaybackPreferencesStore(defaults: defaults)
        #expect(store.preferences.playerPool == .normal)
        store.update { $0.playerPool = .less }
        #expect(MediaPlaybackPreferencesStore(defaults: defaults).preferences.playerPool == .less)
    }

    /// The Lock Screen's lines: the caption's first line and the author.
    @Test func theLockScreenNamesTheClipAndItsAuthor() {
        #expect(SnapFeedViewController.nowPlaying(for: nil) == NowPlayingInfo(title: "Video", artist: ""))
    }

    @Test func thePolicyReadsTheStoreAndTheNetwork() {
        let previousStore = MediaPlaybackPolicy.store
        let previousNetwork = MediaPlaybackPolicy.isOnCellular
        defer {
            MediaPlaybackPolicy.store = previousStore
            MediaPlaybackPolicy.isOnCellular = previousNetwork
        }
        MediaPlaybackPolicy.store = store {
            $0.autoplay = .wifiOnly
            $0.dataSaver = true
        }
        MediaPlaybackPolicy.isOnCellular = { true }
        #expect(!MediaPlaybackPolicy.autoplays)
        #expect(!MediaPlaybackPolicy.preloads)
        #expect(MediaPlaybackPolicy.peakBitRate > 0)
        MediaPlaybackPolicy.isOnCellular = { false }
        #expect(MediaPlaybackPolicy.autoplays)
        #expect(MediaPlaybackPolicy.preloads)
        #expect(MediaPlaybackPolicy.peakBitRate == 0)
    }

    /// The session starts where the preference says, the mute button
    /// overrides it for the session, and a new preference wins again.
    @Test func feedSoundStartsFromThePreference() async {
        let previousStore = MediaPlaybackPolicy.store
        defer {
            MediaPlaybackPolicy.store = previousStore
            FeedSound.reset()
        }
        let quiet = store { $0.startsWithSound = false }
        MediaPlaybackPolicy.store = quiet
        FeedSound.reset()
        #expect(!FeedSound.isOn)
        FeedSound.toggle()
        #expect(FeedSound.isOn)
        quiet.update { $0.startsWithSound = true }
        quiet.update { $0.startsWithSound = false }
        // The observer hops to the main queue.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!FeedSound.isOn, "a new preference drops the session's choice")
    }
}
