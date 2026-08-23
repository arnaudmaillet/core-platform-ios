import Testing
@testable import PostGrid

/// The retention policy, page by page.
///
/// Pure input, pure output — so these say what the window PROMISES, and the
/// hosting tests are free to check only that the promise is carried out.
@Suite struct CarouselRetentionWindowTests {
    private func retained(
        _ videoPages: [Int], on page: Int, capacity: Int = 6
    ) -> [Int] {
        CarouselRetentionWindow.pagesToRetain(
            videoPages: videoPages, currentPage: page, capacity: capacity
        )
    }

    @Test func theWatchedClipIsAlwaysKept() {
        #expect(retained([0, 3, 7], on: 3).first == 3)
    }

    @Test func neighboursAreKeptNearestFirst() {
        // Distances from 5: 4→1, 7→2, 1→4, 12→7.
        #expect(retained([1, 4, 7, 12], on: 5) == [4, 7, 1, 12])
    }

    @Test func aTieGoesToThePageAhead() {
        // 2 and 4 are both one away from 3; forward wins.
        #expect(retained([2, 4], on: 3) == [4, 2])
    }

    @Test func stillsNeverConsumeBudget() {
        // Twenty pages, two of them clips: both kept, budget barely touched.
        #expect(retained([6, 13], on: 0, capacity: 6) == [6, 13])
    }

    @Test func aViewerOnAPhotographKeepsTheClipsAround() {
        // Page 5 is a still between two clips — both stay warm.
        #expect(Set(retained([4, 6], on: 5)) == [4, 6])
    }

    /// ⚠️ The case the whole bound exists for.
    @Test func aGalleryLargerThanTheBudgetIsCapped() {
        let manyClips = Array(0..<12)
        let kept = retained(manyClips, on: 6, capacity: 6)
        #expect(kept.count == 6)
        #expect(kept.contains(6))
        // Spent on what is reachable, not on the far end of the gallery.
        #expect(kept.allSatisfy { abs($0 - 6) <= 3 })
    }

    @Test func theOrderIsADropListNotJustARanking() {
        // A caller short of budget drops from the end, so a smaller capacity
        // must be a PREFIX of a larger one — otherwise "drop the last" would
        // silently evict a nearer page than it kept.
        let wide = retained([0, 2, 5, 9, 11], on: 5, capacity: 5)
        for narrower in 1...5 {
            #expect(retained([0, 2, 5, 9, 11], on: 5, capacity: narrower)
                    == Array(wide.prefix(narrower)))
        }
    }

    @Test func noBudgetKeepsNothing() {
        #expect(retained([1, 2], on: 1, capacity: 0).isEmpty)
    }

    @Test func aCollectionWithoutClipsAsksForNothing() {
        #expect(retained([], on: 3).isEmpty)
    }

    @Test func theAnswerDoesNotDependOnTheInputsArrangement() {
        #expect(retained([9, 2, 5], on: 4) == retained([2, 5, 9], on: 4))
    }
}
