import Testing
@testable import Feed

/// A photograph's or a text post's song is silent in Low Power Mode, followed (#1808), like a
/// clip that does not start on its own (#580, the viewer's decision).
@MainActor
struct FeedSongLowPowerModeTests {
    @Test func aPagesSongPlaysOnlyWithTheSoundOnAndLowPowerModeNotFollowed() {
        #expect(SnapSoundState.pageSongPlays(soundOn: true, lowPowerMode: false))
        #expect(!SnapSoundState.pageSongPlays(soundOn: true, lowPowerMode: true), "a song in Low Power Mode, followed")
        #expect(!SnapSoundState.pageSongPlays(soundOn: false, lowPowerMode: false))
        #expect(!SnapSoundState.pageSongPlays(soundOn: false, lowPowerMode: true))
    }
}
