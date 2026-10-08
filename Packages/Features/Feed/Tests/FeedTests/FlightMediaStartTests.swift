import CoreModels
import Testing
@testable import Feed

/// Which page a presenting flight's start position is for (#625).
///
/// ⚠️ A COLD OPEN TAKES OFF BEFORE THE FEED HAS POSTS. The time used to be
/// keyed on `activePostID` at take-off and dropped when there was none — so the
/// page started its clip at zero on exactly the opens whose first frame is late,
/// the ones the landing hand-over was fixed for (#633).
@MainActor
struct FlightMediaStartTests {
    private let carried = PostID("post-new-01")
    private let other = PostID("post-new-02")

    @Test("A flight that named its post starts that post's page, and no other")
    func aNamedPostIsTheOnlyTarget() {
        #expect(SnapFeedViewController.isFlightEntryPage(carried, carried: carried, entry: other))
        #expect(!SnapFeedViewController.isFlightEntryPage(other, carried: carried, entry: other))
    }

    @Test("A flight that took off before the feed had posts starts the entry page once it exists")
    func aColdOpenStartsTheEntryPage() {
        #expect(SnapFeedViewController.isFlightEntryPage(carried, carried: nil, entry: carried))
        #expect(!SnapFeedViewController.isFlightEntryPage(other, carried: nil, entry: carried))
        #expect(!SnapFeedViewController.isFlightEntryPage(carried, carried: nil, entry: nil))
    }
}
