import Testing
@testable import Feed

/// A photograph's or a text post's song is silent under Power Saving, like a
/// clip that does not start on its own (#580, the viewer's decision).
@MainActor
struct FeedSongPowerSavingTests {
    @Test func aPagesSongPlaysOnlyWithTheSoundOnAndPowerSavingOff() {
        #expect(SnapSoundState.pageSongPlays(soundOn: true, powerSaving: false))
        #expect(!SnapSoundState.pageSongPlays(soundOn: true, powerSaving: true), "a song under Power Saving")
        #expect(!SnapSoundState.pageSongPlays(soundOn: false, powerSaving: false))
        #expect(!SnapSoundState.pageSongPlays(soundOn: false, powerSaving: true))
    }
}
