import DesignSystem
import FeedInterface
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
        #expect(!page.debugBonesVisible, "a bone before the delay")
        time.advance(LoadingTiming.skeletonDelay)
        #expect(page.debugBonesVisible)
    }

    @Test func aPageThatAnswersAtOnceShowsNoBone() {
        let time = ManualClock()
        let page = page(time)
        page.render(.loading)
        page.render(.content([]))
        time.advance(1)
        #expect(!page.debugBonesVisible)
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
        #expect(!page.debugBonesVisible)
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

    // MARK: - A host's answers end the load too (#1900)

    private static let lock = PostGridPageStatus(
        symbolName: "lock", title: "This Account Is Private", subtitle: "Follow this account to see their posts."
    )

    private func tryAgain(in view: UIView) -> UIButton? {
        for subview in view.subviews {
            if let button = subview as? UIButton, !button.isHidden, button.configuration?.title == "Try Again" { return button }
            if let found = tryAgain(in: subview) { return found }
        }
        return nil
    }

    /// A private profile's lock answering before the delay: no bone lands
    /// under it, and no "taking longer" replaces it.
    @Test func aHostStatusBeforeTheDelayEndsTheLoad() {
        let time = ManualClock()
        let page = page(time)
        page.show(.loading)
        page.show(.status(Self.lock))
        time.advance(LoadingTiming.skeletonDelay)
        #expect(!page.debugBonesVisible, "bones under the lock")
        time.advance(LoadingTiming.takingLonger)
        #expect(label("Taking longer than usual", in: page) == nil, "taking longer over an answer")
        #expect(label(Self.lock.title, in: page) != nil, "the lock went")
    }

    /// The lock answering once the bones are up: they go after their
    /// minimum, and the lock stays past the long wait.
    @Test func aHostStatusAfterTheBonesEndsTheLoad() {
        let time = ManualClock()
        let page = page(time)
        page.show(.loading)
        time.advance(LoadingTiming.skeletonDelay)
        #expect(page.debugBonesVisible)
        page.show(.status(Self.lock))
        time.advance(1)
        #expect(!page.debugBonesVisible)
        #expect(label(Self.lock.title, in: page) != nil)
        time.advance(LoadingTiming.takingLonger)
        #expect(label("Taking longer than usual", in: page) == nil)
        #expect(label(Self.lock.title, in: page) != nil)
    }

    /// History's titled groups end the load too.
    @Test func hostSectionsEndTheLoad() {
        let time = ManualClock()
        let page = ForYouGridPage(imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), style: .discover, videoPlayback: nil)
        page.skeletonClock = time.clock
        page.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        page.layoutIfNeeded()
        page.show(.loading)
        page.show(.sections([]))
        time.advance(LoadingTiming.skeletonDelay)
        #expect(!page.debugBonesVisible)
        time.advance(LoadingTiming.takingLonger)
        #expect(label("Taking longer than usual", in: page) == nil)
    }

    /// Try Again over a page that had its answer: the page goes back to
    /// loading, and the host's answer — the very same — lands again.
    @Test func tryAgainHearsTheSameAnswerAgain() {
        let time = ManualClock()
        let page = page(time)
        page.show(.loading)
        time.advance(LoadingTiming.skeletonDelay)
        time.advance(LoadingTiming.takingLonger)
        #expect(label("Taking longer than usual", in: page) != nil)
        var retries = 0
        page.onRefresh = {
            retries += 1
            page.show(.status(Self.lock))
        }
        tryAgain(in: page)?.sendActions(for: .primaryActionTriggered)
        #expect(retries == 1)
        time.advance(1)
        #expect(label("Taking longer than usual", in: page) == nil, "Try Again left taking longer on screen")
        #expect(label(Self.lock.title, in: page) != nil, "the answer did not land again")
    }
}
