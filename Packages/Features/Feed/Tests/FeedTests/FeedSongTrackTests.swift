import AVFoundation
import Foundation
import Testing
@testable import Feed

/// A carousel's track (#1849): one track for the post, which a page change
/// never restarts, and which another post starts again from its start.
@MainActor
struct FeedSongTrackTests {
    private static let song = URL(fileURLWithPath: "/tmp/track-1849.m4a")

    /// The screen asks again on every page change (`refreshSong`), with the
    /// same post's same track: the player keeps the item it is playing.
    @Test func aPageChangeKeepsTheTrackItWasPlaying() {
        let player = FeedSongPlayer(items: { AVPlayerItem(url: $0) })
        player.play(Self.song)
        let item = player.currentItem
        player.play(Self.song)
        #expect(player.currentItem === item, "turning a page restarted the post's track")
        // A pause keeps the item, and so the position.
        player.play(nil)
        player.play(Self.song)
        #expect(player.currentItem === item)
    }

    /// Another post set to the same song starts it again: the screen stops
    /// the player when the page that owns the screen changes post.
    @Test func anotherPostStartsTheTrackAgain() {
        let player = FeedSongPlayer(items: { AVPlayerItem(url: $0) })
        player.play(Self.song)
        let item = player.currentItem
        player.stop()
        player.play(Self.song)
        #expect(player.currentItem !== item)
    }
}
