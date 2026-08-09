import Testing
@testable import Feed

/// HOW MANY VIDEOS EACH SHAPE MAY PLAY AT ONCE.
///
/// The only thing left that differs between the mosaic's playback and the
/// timeline's. Both rank candidates by distance from the viewport centre and
/// keep the nearest N; this is N, and it is a judgement rather than a
/// derivation, so it is worth stating somewhere that fails when someone changes
/// it by accident.
///
/// The ceiling that matters is not the screen but the shared idle-player cache,
/// which is six. Two pages draw on it, and only the active one plays, so a
/// timeline asking for more than the cache holds would drop a returned player
/// on every scroll instead of reusing it.
struct ForYouPlaybackConcurrencyTests {
    @Test func theMosaicPlaysSixAndTheTimelineFive() {
        #expect(ForYouGridPage.concurrentPlayers(for: .grid) == 6)
        #expect(ForYouGridPage.concurrentPlayers(for: .list) == 5)
    }

    /// A timeline row used to be excluded from playback outright, then allowed
    /// exactly one. Both are gone; what must not come back is a value that
    /// leaves the page effectively silent.
    @Test func theTimelineIsNoLongerCappedAtASinglePlayer() {
        #expect(ForYouGridPage.concurrentPlayers(for: .list) > 1)
    }

    /// Neither may exceed the shared idle-player cache.
    @Test func neitherShapeOutrunsThePlayerCache() {
        let cacheSize = 6
        for style in [ForYouGridPage.Style.grid, .list] {
            #expect(ForYouGridPage.concurrentPlayers(for: style) <= cacheSize)
        }
    }
}
