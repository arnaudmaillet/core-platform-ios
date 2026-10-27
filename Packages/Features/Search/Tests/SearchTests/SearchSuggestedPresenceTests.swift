import Testing
@testable import Search

/// SECTIONS BY PRESENCE (#1773): Suggested wears bones only when it had rows
/// last time, or was never seen — as many as it had, up to the fold.
@MainActor
struct SearchSuggestedPresenceTests {
    @Test func anEmptySuggestedLastTimeWearsNoBones() {
        #expect(SearchViewController.suggestedSkeletonCount(remembered: 0) == 0)
        #expect(SearchViewController.suggestedSkeletonCount(remembered: 2) == 2)
        #expect(SearchViewController.suggestedSkeletonCount(remembered: 40) == 5)
        #expect(SearchViewController.suggestedSkeletonCount(remembered: nil) == 5)
    }
}
