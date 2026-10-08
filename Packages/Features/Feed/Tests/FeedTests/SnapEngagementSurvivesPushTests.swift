import Testing
@testable import Feed

/// The comments layout survives a pushed screen (#698): covering the feed
/// resigns its page in place, and only a real page change retires the
/// engagement.
@MainActor
struct SnapEngagementSurvivesPushTests {
    @Test func aCoveredScreenKeepsTheEngagement() {
        // Pushed hashtag or profile: the settled page is still the engaged one.
        #expect(!SnapFeedViewController.resignRetiresEngagement(resting: false, settledPage: 4, resigned: 4))
    }

    @Test func aPageChangeStillRetiresIt() {
        #expect(SnapFeedViewController.resignRetiresEngagement(resting: false, settledPage: 5, resigned: 4))
    }

    /// A resting engagement (a text page) waits for its last pixel to leave,
    /// whichever way the page went (`didEndDisplaying`).
    @Test func aRestingEngagementIsNeverRetiredHere() {
        #expect(!SnapFeedViewController.resignRetiresEngagement(resting: true, settledPage: 5, resigned: 4))
        #expect(!SnapFeedViewController.resignRetiresEngagement(resting: true, settledPage: 4, resigned: 4))
    }
}
