import Testing
@testable import Feed

/// What the full-screen pager gets ready, and how far.
///
/// The numbers are the point of this suite, so they are asserted rather than
/// merely defined: two pages of CONTENT ahead and one behind, and players only
/// on the immediate neighbours — three in total with the active page's, which
/// is the pool every comparable short-video feed runs.
///
/// The asymmetry is what a reader is most likely to "tidy" into one number, so
/// it is pinned from both sides.
struct SnapWarmWindowTests {
    /// ⚠️ NEAREST FIRST, AND AHEAD BEFORE BEHIND.
    ///
    /// These indices are handed to work that runs in sequence and can be
    /// outrun by a fast scroll, so the page the viewer is most likely to reach
    /// next has to be asked for first. Returned in index order, the window
    /// would warm the page BEHIND before the page ahead for every active page
    /// but the first.
    @Test func theWindowIsOrderedByHowSoonThePageIsNeeded() {
        let window = SnapWarmWindow.indices(around: 5, count: 20, ahead: 2, behind: 1)

        #expect(window == [6, 4, 7])
    }

    /// Content reaches further than players do, and the two windows are
    /// deliberately different numbers.
    @Test func contentReachesFurtherThanPlayersDo() {
        #expect(SnapWarmWindow.content(around: 5, count: 20) == [6, 4, 7])
        #expect(SnapWarmWindow.players(around: 5, count: 20) == [6, 4])
    }

    /// ⚠️ THREE PLAYERS IN TOTAL, counting the one the viewer is watching.
    ///
    /// A player holds a decoder and the platform caps how many can render at
    /// once; this window is the one warm that has to stay stingy.
    @Test func thePlayerWindowIsThreeCountingTheActivePage() {
        let neighbours = SnapWarmWindow.players(around: 8, count: 40)

        #expect(neighbours.count == 2)
        #expect(Set(neighbours) == [7, 9])
    }

    /// The ends of the feed clamp rather than wrapping or running past.
    @Test func theWindowStopsAtBothEndsOfTheFeed() {
        #expect(SnapWarmWindow.content(around: 0, count: 20) == [1, 2])
        #expect(SnapWarmWindow.content(around: 19, count: 20) == [18])
        #expect(SnapWarmWindow.content(around: 0, count: 1).isEmpty)
    }

    /// A feed with nothing in it, and an index that is not in it, both answer
    /// nothing rather than trapping — the pager asks this on every settle,
    /// including the ones that race a corpus being replaced.
    @Test func anEmptyOrImpossibleWindowIsAnswerable() {
        #expect(SnapWarmWindow.content(around: 0, count: 0).isEmpty)
        #expect(SnapWarmWindow.content(around: 7, count: 3).isEmpty)
        #expect(SnapWarmWindow.content(around: -1, count: 10).isEmpty)
    }

    /// A window of one either side still covers both, which is what makes a
    /// truncated warm proportional rather than one-sided.
    @Test func bothSidesAreCoveredBeforeEitherIsExtended() {
        let window = SnapWarmWindow.indices(around: 10, count: 40, ahead: 3, behind: 1)

        #expect(window == [11, 9, 12, 13])
    }
}
