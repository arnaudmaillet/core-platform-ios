import AVFoundation
import Foundation
import Testing
@testable import MediaPlayback

/// Where a clip had got to when its player was let go.
///
/// ⚠️ THE POOL IS DOING ITS JOB; NOTHING WAS WRITING DOWN WHAT IT DISCARDED.
/// Closing a post returns its player to the pool, and `retire` replaces the
/// item with nil — so every re-open of the same post minted a fresh player and
/// began the clip again at zero. Measured off the scrub bar over three
/// open/close cycles: 4%, then 1.5%, then 0.5%.
///
/// These assert the LEDGER rather than playback, deliberately. A test drives a
/// real `AVPlayer` over a stub URL, whose playhead never leaves zero, so a test
/// written through `play` would pass whatever the rules said.
@MainActor
struct PlayheadResumeTests {
    private struct StubSource: VideoSource {
        func playableURL(for url: URL) async throws -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("stub.mp4")
        }
    }

    private func pool() -> VideoPlaybackController {
        VideoPlaybackController(source: StubSource(), poolSize: 4, capacity: 4)
    }

    private let clip = URL(string: "mock://video/trailer")!
    private func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 600)
    }

    @Test func aFiledPositionComesBackForTheSamePost() {
        let pool = pool()
        pool.rememberResume(scope: "post-a", url: clip, at: seconds(21.5))
        let resumed = pool.takeResume(scope: "post-a", url: clip)
        #expect(resumed?.seconds == 21.5)
    }

    /// ⚠️ THE SCOPE IS PART OF THE KEY, which is the same identity rule the
    /// player pool itself follows: two rows carrying one file are two viewings.
    /// Keyed by asset alone, one viewer's place would land on the other's screen.
    @Test func twoPostsSharingAFileKeepSeparatePositions() {
        let pool = pool()
        pool.rememberResume(scope: "post-a", url: clip, at: seconds(21.5))
        pool.rememberResume(scope: "post-b", url: clip, at: seconds(3))

        #expect(pool.takeResume(scope: "post-a", url: clip)?.seconds == 21.5)
        #expect(pool.takeResume(scope: "post-b", url: clip)?.seconds == 3)
    }

    /// Spent once. A second cold start for the same post is a clip the viewer
    /// has since watched past — or restarted — and dragging it back to a stale
    /// position is worse than starting it.
    @Test func aPositionIsConsumedByTheStartThatUsesIt() {
        let pool = pool()
        pool.rememberResume(scope: "post-a", url: clip, at: seconds(21.5))
        #expect(pool.takeResume(scope: "post-a", url: clip) != nil)
        #expect(pool.takeResume(scope: "post-a", url: clip) == nil)
    }

    /// Below the threshold there is nothing to resume TO: the seek would cost a
    /// decode on every cold start in the app to land where the clip begins.
    @Test func aPositionAtTheVeryStartIsNotWorthKeeping() {
        let pool = pool()
        pool.rememberResume(scope: "post-a", url: clip, at: seconds(0.2))
        #expect(pool.takeResume(scope: "post-a", url: clip) == nil)
    }

    /// An invalid or non-finite time is what a player with no item answers, and
    /// seeking to it would be undefined.
    @Test func anUnknownPositionIsNotFiled() {
        let pool = pool()
        pool.rememberResume(scope: "post-a", url: clip, at: .invalid)
        pool.rememberResume(scope: "post-b", url: clip, at: .indefinite)
        #expect(pool.takeResume(scope: "post-a", url: clip) == nil)
        #expect(pool.takeResume(scope: "post-b", url: clip) == nil)
    }

    /// This is "the clip you were just watching", not a viewing history, so the
    /// memory is capped and the oldest entry goes first.
    @Test func theMemoryIsCappedAndEvictsTheOldest() {
        let pool = pool()
        for index in 0..<40 {
            pool.rememberResume(
                scope: "post-\(index)", url: clip, at: seconds(Double(index) + 1)
            )
        }
        #expect(pool.takeResume(scope: "post-0", url: clip) == nil)
        #expect(pool.takeResume(scope: "post-39", url: clip)?.seconds == 40)
    }

    /// Re-filing the same post overwrites rather than queueing, so a long
    /// session on one clip cannot evict everything else behind it.
    @Test func refilingOnePostDoesNotConsumeTheMemoryTwice() {
        let pool = pool()
        pool.rememberResume(scope: "post-a", url: clip, at: seconds(5))
        pool.rememberResume(scope: "post-a", url: clip, at: seconds(9))
        for index in 0..<31 {
            pool.rememberResume(scope: "other-\(index)", url: clip, at: seconds(2))
        }
        #expect(pool.takeResume(scope: "post-a", url: clip)?.seconds == 9)
    }
}
