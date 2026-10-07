import Testing
@testable import Feed

/// A photograph's or a text post's song is silent under Power Saving, like a
/// clip that does not start on its own (#580, the viewer's decision).
@MainActor
struct FeedSongPowerSavingTests {
    @Test func aPagesSongPlaysOnlyWithTheSoundOnAndPowerSavingOff() {
        #expect(SnapFeedViewController.pageSongPlays(soundOn: true, powerSaving: false))
        #expect(!SnapFeedViewController.pageSongPlays(soundOn: true, powerSaving: true), "a song under Power Saving")
        #expect(!SnapFeedViewController.pageSongPlays(soundOn: false, powerSaving: false))
        #expect(!SnapFeedViewController.pageSongPlays(soundOn: false, powerSaving: true))
    }
}
