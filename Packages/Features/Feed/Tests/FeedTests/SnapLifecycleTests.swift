import Testing
@testable import Feed

/// The snap feed's paging math and activation state machine, exercised without
/// a live scroll view or UIKit.
struct SnapActiveItemTrackerTests {
    @Test func roundsToNearestPage() {
        #expect(SnapActiveItemTracker.activeIndex(contentOffsetY: 0, pageHeight: 800, itemCount: 3) == 0)
        #expect(SnapActiveItemTracker.activeIndex(contentOffsetY: 399, pageHeight: 800, itemCount: 3) == 0)
        #expect(SnapActiveItemTracker.activeIndex(contentOffsetY: 401, pageHeight: 800, itemCount: 3) == 1)
        #expect(SnapActiveItemTracker.activeIndex(contentOffsetY: 1600, pageHeight: 800, itemCount: 3) == 2)
    }

    @Test func clampsPastTheEndsAndGuardsDegenerateInput() {
        #expect(SnapActiveItemTracker.activeIndex(contentOffsetY: 999_999, pageHeight: 800, itemCount: 3) == 2)
        #expect(SnapActiveItemTracker.activeIndex(contentOffsetY: -50, pageHeight: 800, itemCount: 3) == 0)
        #expect(SnapActiveItemTracker.activeIndex(contentOffsetY: 0, pageHeight: 0, itemCount: 3) == nil)
        #expect(SnapActiveItemTracker.activeIndex(contentOffsetY: 0, pageHeight: 800, itemCount: 0) == nil)
    }
}

struct SnapLifecycleDispatcherTests {
    @Test func scrollingBetweenVisiblePagesResignsAndActivates() {
        var dispatcher = SnapLifecycleDispatcher()
        #expect(dispatcher.setVisible(true) == .none) // no page snapped yet
        #expect(dispatcher.setPageIndex(0) == .init(resign: nil, activate: 0))
        #expect(dispatcher.setPageIndex(1) == .init(resign: 0, activate: 1))
    }

    @Test func hidingSurfaceResignsActiveAndRestoringReactivates() {
        var dispatcher = SnapLifecycleDispatcher()
        _ = dispatcher.setVisible(true)
        _ = dispatcher.setPageIndex(2)
        #expect(dispatcher.setVisible(false) == .init(resign: 2, activate: nil))
        #expect(dispatcher.setVisible(true) == .init(resign: nil, activate: 2))
    }

    @Test func pageChangesWhileHiddenProduceNoTransitionUntilVisible() {
        var dispatcher = SnapLifecycleDispatcher()
        _ = dispatcher.setPageIndex(0) // surface not visible
        #expect(dispatcher.setPageIndex(1) == .none)
        #expect(dispatcher.setVisible(true) == .init(resign: nil, activate: 1))
    }

    @Test func redundantSetsAreNoOps() {
        var dispatcher = SnapLifecycleDispatcher()
        _ = dispatcher.setVisible(true)
        _ = dispatcher.setPageIndex(0)
        #expect(dispatcher.setPageIndex(0) == .none)
        #expect(dispatcher.setVisible(true) == .none)
    }
}
