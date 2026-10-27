import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Search

/// The Users tab's first-query skeleton on the kit's timing (#1770): nothing
/// for the delay, the bones held their minimum once up, and "Taking longer
/// than usual" with Try Again when the search never answers.
@MainActor
struct SearchPeopleSkeletonGateTests {
    private func page(_ time: ManualLoadingClock) -> SearchPeoplePage {
        let page = SearchPeoplePage(imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
        page.skeletonClock = time.clock
        page.loadViewIfNeeded()
        page.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        page.view.layoutIfNeeded()
        return page
    }

    @Test func noBonesBeforeTheDelayThenTheBones() {
        let time = ManualLoadingClock()
        let page = page(time)
        page.render(.loading)
        #expect(!page.debugShowsSkeleton, "a bone before the delay")
        time.advance(LoadingTiming.skeletonDelay)
        #expect(page.debugShowsSkeleton)
    }

    @Test func anAnswerAfterTheBonesWaitsOutTheirMinimum() {
        let time = ManualLoadingClock()
        let page = page(time)
        page.render(.loading)
        time.advance(LoadingTiming.skeletonDelay)
        page.render(.empty(query: "zz"))
        #expect(page.debugStatusTitle == nil, "the answer cut the bones short")
        time.advance(LoadingTiming.minimum)
        #expect(page.debugStatusTitle == "No results")
    }

    @Test func takingLongerOffersTryAgain() {
        let time = ManualLoadingClock()
        let page = page(time)
        var retries = 0
        page.onRetry = { retries += 1 }
        page.render(.loading)
        time.advance(LoadingTiming.takingLonger)
        #expect(page.debugStatusTitle == TakingLongerCopy.title)
        page.debugTapStatusAction()
        #expect(retries == 1)

        // Try Again: the wait starts over, and an answer lands as usual.
        page.render(.loading)
        #expect(page.debugStatusTitle == nil)
        page.render(.empty(query: "zz"))
        #expect(page.debugStatusTitle == "No results")
    }
}
