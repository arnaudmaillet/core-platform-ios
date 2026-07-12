import Testing
import UIKit
@testable import Feed

@MainActor
struct SnapCommentTickerViewTests {
    private func makeTicker(itemCount: Int = 12) -> SnapCommentTickerView {
        let ticker = SnapCommentTickerView(frame: CGRect(x: 0, y: 0, width: 400, height: 69))
        ticker.setComments((0..<itemCount).map { TickerCommentModel(id: "r\($0)", text: "GG 🔥 \($0)") })
        return ticker
    }

    /// The cold-start contract: the instant the band activates, every lane is
    /// already populated and every bubble is in flight — no empty first
    /// seconds, no one-by-one crawl-in from the right edge.
    @Test func activationPrefillsTheVisibleBand() {
        let ticker = makeTicker()
        ticker.setActive(true)

        #expect(ticker.subviews.count >= SnapCommentTickerView.laneCount)
        #expect(ticker.subviews.allSatisfy { $0.layer.animation(forKey: "flight") != nil })
    }

    @Test func deactivationClearsEveryBubble() {
        let ticker = makeTicker()
        ticker.setActive(true)
        #expect(!ticker.subviews.isEmpty)

        ticker.setActive(false)
        #expect(ticker.subviews.isEmpty)
    }

    @Test func emptyQueueKeepsTheBandHiddenAndUnpopulated() {
        let ticker = SnapCommentTickerView(frame: CGRect(x: 0, y: 0, width: 400, height: 69))
        ticker.setComments([])
        ticker.setActive(true)

        #expect(ticker.isHidden)
        #expect(ticker.subviews.isEmpty)
    }
}
