import CoreStorage
import Foundation
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
