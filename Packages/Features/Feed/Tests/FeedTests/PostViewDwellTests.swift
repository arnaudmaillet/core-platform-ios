import CoreModels
import Foundation
import Testing
@testable import Feed

/// The vertical feed's "viewed" rule (#1344): a post that stays the active
/// page for the dwell is recorded once; one that resigns first is not.
@MainActor
struct PostViewDwellTests {
    private func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    @Test func aPostThatStaysIsRecordedOnce() async {
        var recorded: [PostID] = []
        let dwell = PostViewDwell(delay: 0.05) { recorded.append($0) }
        dwell.begin(PostID("a"))
        await wait(0.2)
        #expect(recorded == [PostID("a")])
    }

    @Test func aSwipePastIsNotRecorded() async {
        var recorded: [PostID] = []
        let dwell = PostViewDwell(delay: 0.1) { recorded.append($0) }
        dwell.begin(PostID("fast"))
        await wait(0.02)
        dwell.end()
        dwell.begin(PostID("stays"))
        await wait(0.3)
        #expect(recorded == [PostID("stays")], "a page swiped past within the dwell was recorded")
    }

    @Test func aPageCoveredBeforeTheDwellIsNotRecorded() async {
        var recorded: [PostID] = []
        let dwell = PostViewDwell(delay: 0.1) { recorded.append($0) }
        dwell.begin(PostID("a"))
        dwell.end()
        await wait(0.25)
        #expect(recorded.isEmpty)
    }
}
