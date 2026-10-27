import DesignSystem
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Feed

/// The For You grid's cold skeleton on the kit's timing (#1770): nothing for
/// the delay, the bones after it, and "Taking longer than usual" with Try
/// Again when the page never answers.
@MainActor
struct GridSkeletonGateTests {
    @MainActor
    private final class ManualClock {
        var now: TimeInterval = 0
        private var pending: [(at: TimeInterval, work: @MainActor () -> Void)] = []
        var clock: LoadingClock {
            LoadingClock(now: { [weak self] in self?.now ?? 0 }, after: { [weak self] delay, work in
                guard let self else { return }
                pending.append((now + delay, work))
            })
        }
        func advance(_ seconds: TimeInterval) {
            now += seconds
            while let index = pending.indices.filter({ pending[$0].at <= now }).min(by: { pending[$0].at < pending[$1].at }) {
                pending.remove(at: index).work()
            }
        }
    }

    private func label(_ text: String, in view: UIView) -> UILabel? {
        for subview in view.subviews {
            if let label = subview as? UILabel, label.text == text, !label.isHidden { return label }
            if let found = label(text, in: subview) { return found }
        }
        return nil
    }

    private func page(_ time: ManualClock) -> ForYouGridPage {
        let page = ForYouGridPage(imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), style: .grid, videoPlayback: nil)
        page.skeletonClock = time.clock
        page.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        page.layoutIfNeeded()
        return page
    }

    @Test func noBonesBeforeTheDelayThenTheBones() {
        let time = ManualClock()
        let page = page(time)
        page.render(.loading)
        #expect(!page.debugShowsSkeleton, "a bone before the delay")
        time.advance(LoadingTiming.skeletonDelay)
        #expect(page.debugShowsSkeleton)
    }

    @Test func aPageThatAnswersAtOnceShowsNoBone() {
        let time = ManualClock()
        let page = page(time)
        page.render(.loading)
        page.render(.content([]))
        time.advance(1)
        #expect(!page.debugShowsSkeleton)
    }

    @Test func takingLongerOffersTryAgain() {
        let time = ManualClock()
        let page = page(time)
        var retries = 0
        page.onRefresh = { retries += 1 }
        page.render(.loading)
        time.advance(LoadingTiming.skeletonDelay)
        time.advance(LoadingTiming.takingLonger)
        #expect(label("Taking longer than usual", in: page) != nil)
        #expect(!page.debugShowsSkeleton)
        func button(in view: UIView) -> UIButton? {
            for subview in view.subviews {
                if let button = subview as? UIButton, !button.isHidden, button.configuration?.title == "Try Again" { return button }
                if let found = button(in: subview) { return found }
            }
            return nil
        }
        button(in: page)?.sendActions(for: .primaryActionTriggered)
        #expect(retries == 1)
    }
}
