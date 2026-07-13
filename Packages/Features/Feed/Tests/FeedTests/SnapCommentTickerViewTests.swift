import Testing
import UIKit
@testable import Feed

@MainActor
struct SnapCommentTickerViewTests {
    private let bandWidth: CGFloat = 400

    private func makeTicker(itemCount: Int = 12) -> SnapCommentTickerView {
        let ticker = SnapCommentTickerView(frame: CGRect(x: 0, y: 0, width: bandWidth, height: 69))
        ticker.setComments((0..<itemCount).map { TickerCommentModel(id: "r\($0)", text: "GG 🔥 \($0)") })
        return ticker
    }

    private func bubbleLabels(_ ticker: SnapCommentTickerView) -> [UILabel] {
        ticker.subviews.compactMap { $0 as? UILabel }
    }

    /// The cold-start contract: the instant the band activates, every lane is
    /// already populated and every bubble is in flight — no empty first
    /// seconds, no one-by-one crawl-in from the right edge.
    @Test func activationPrefillsTheVisibleBand() {
        let ticker = makeTicker()
        ticker.setActive(true)

        let labels = bubbleLabels(ticker)
        #expect(labels.count >= SnapCommentTickerView.laneCount)
        #expect(labels.allSatisfy { $0.layer.animation(forKey: "flight") != nil })
    }

    @Test func deactivationClearsEveryBubble() {
        let ticker = makeTicker()
        ticker.setActive(true)
        #expect(!bubbleLabels(ticker).isEmpty)

        ticker.setActive(false)
        #expect(bubbleLabels(ticker).isEmpty)
    }

    @Test func emptyQueueKeepsTheBandHiddenAndUnpopulated() {
        let ticker = SnapCommentTickerView(frame: CGRect(x: 0, y: 0, width: bandWidth, height: 69))
        ticker.setComments([])
        ticker.setActive(true)

        #expect(ticker.isHidden)
        #expect(bubbleLabels(ticker).isEmpty)
    }

    // MARK: - Scrub

    /// Grabbing the band freezes CA flights into model positions: every
    /// bubble keeps an on-screen coordinate and no animation remains.
    @Test func beginScrubFreezesFlightsIntoModelPositions() {
        let ticker = makeTicker()
        ticker.setActive(true)

        ticker.beginScrub()

        let labels = bubbleLabels(ticker)
        #expect(!labels.isEmpty)
        #expect(labels.allSatisfy { $0.layer.animation(forKey: "flight") == nil })
        // Frozen positions are the visible train, not the parked exit values.
        #expect(labels.contains { $0.layer.position.x > 0 })
    }

    /// Dragging displaces the surviving bubbles exactly with the finger, and
    /// backfill keeps the band covered right up to the entry edge in both
    /// scrub directions.
    @Test func scrubTranslatesAndBackfillsBothDirections() {
        let ticker = makeTicker()
        ticker.setActive(true)
        ticker.beginScrub()

        // Only mid-band labels: ones near the left edge retire under the
        // translation and their (pooled) label can be reused by backfill in
        // the same pass, which would alias the identity check.
        let before = Dictionary(
            uniqueKeysWithValues: bubbleLabels(ticker)
                .filter { (150..<300).contains($0.layer.position.x) }
                .map { ($0, $0.layer.position.x) }
        )
        #expect(!before.isEmpty)

        ticker.applyScrubTranslation(-120) // scrub forward
        for (label, x) in before {
            #expect(abs(label.layer.position.x - (x - 120)) < 0.5)
        }
        let rightmostAfterForward = bubbleLabels(ticker).map { $0.frame.maxX }.max() ?? 0
        #expect(rightmostAfterForward > bandWidth - SnapCommentTickerView.interItemGap - 48)

        ticker.applyScrubTranslation(600) // scrub far backward: rewinds the queue
        let labels = bubbleLabels(ticker)
        #expect(!labels.isEmpty)
        let leftmostAfterBackward = labels.map { $0.frame.minX }.min() ?? 0
        #expect(leftmostAfterBackward < SnapCommentTickerView.interItemGap + 48)
    }

    /// A release near the drift hands back to CA: flights reattach and the
    /// train keeps flowing. Needs a real window — flights on layers outside
    /// a render tree "complete" immediately, which would recycle everything.
    @Test func releaseHandsBubblesBackToTheConveyor() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: bandWidth, height: 100))
        let ticker = makeTicker()
        window.addSubview(ticker)
        window.isHidden = false
        defer { window.isHidden = true }

        ticker.setActive(true)
        ticker.beginScrub()
        ticker.applyScrubTranslation(-60)

        ticker.endScrub(releaseVelocity: -24) // near drift → immediate handover
        // Give the render server a beat; steady flights run for many seconds,
        // so the train must still be flowing afterwards.
        try await Task.sleep(for: .seconds(1.0))

        let labels = bubbleLabels(ticker)
        #expect(!labels.isEmpty)
        #expect(labels.allSatisfy { $0.layer.animation(forKey: "flight") != nil })
    }

    // MARK: - Device-bug regressions (2026-07-13)

    /// Bug 1: the band's pan must preempt other pan recognizers (timeline
    /// slide-to-pop, pin grab) over its own frame — they are required to
    /// wait for the band's pan to fail.
    @Test func bandPanPreemptsOtherPanRecognizers() throws {
        let ticker = makeTicker()
        let bandPan = try #require(ticker.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first)
        let dismissalPan = UIPanGestureRecognizer()
        let tap = UITapGestureRecognizer()

        #expect(ticker.gestureRecognizer(bandPan, shouldBeRequiredToFailBy: dismissalPan))
        // Taps (play/pause) are not held hostage.
        #expect(!ticker.gestureRecognizer(bandPan, shouldBeRequiredToFailBy: tap))
    }

    /// Bug 2: the entry spawn is geometry-checked — an uncleared entry edge
    /// (e.g. the layer clock frozen by a percent-driven transition while
    /// wall-clock timers keep firing) defers the spawn instead of stacking a
    /// new bubble onto the frozen one.
    @Test func entrySpawnDefersUntilTheGapIsOpen() {
        // Rightmost bubble frozen exactly at the entry edge: the full
        // (width-independent) gap must elapse first.
        let blocked = SnapCommentTickerView.entryDeferral(lastRightEdge: 400, bandWidth: 400, speed: 22)
        #expect(abs(blocked - TimeInterval(SnapCommentTickerView.interItemGap / 22)) < 0.001)

        // Gap already open → no deferral.
        let clear = SnapCommentTickerView.entryDeferral(
            lastRightEdge: 400 - SnapCommentTickerView.interItemGap, bandWidth: 400, speed: 22
        )
        #expect(clear == 0)

        // Beyond-open never goes negative.
        #expect(SnapCommentTickerView.entryDeferral(lastRightEdge: 100, bandWidth: 400, speed: 22) == 0)
    }

    /// Bug 3: the kinetic blur must engage during manual control — a live,
    /// fraction-driven animator while the coast is fast (an `.inactive`
    /// animator silently ignores `fractionComplete`), disengaged at
    /// handover, where the reversal run owns the fade-out.
    @Test func kineticBlurEngagesDuringCoastAndDisengagesAtHandover() throws {
        let ticker = makeTicker()
        ticker.setActive(true)
        ticker.beginScrub()
        ticker.applyScrubTranslation(-40)
        ticker.endScrub(releaseVelocity: 1200)

        let blur = try #require(
            ticker.subviews.first { $0.accessibilityIdentifier == "ticker-kinetic-backdrop" }
        )
        let start = CACurrentMediaTime()
        ticker.coastStep(now: start + 0.016) // one fast frame into the decay
        #expect(!blur.isHidden)
        #expect(ticker.currentKineticFraction > 0)

        ticker.coastStep(now: start + 30) // decay long settled → handover
        #expect(ticker.currentKineticFraction == 0) // disengaged; reversal fades out
        let labels = bubbleLabels(ticker)
        #expect(!labels.isEmpty)
        #expect(labels.allSatisfy { $0.layer.animation(forKey: "flight") != nil })
    }

    /// The backdrop is a true accumulator during a touch: monotone
    /// non-decreasing in accumulated absolute travel — floor at touch-down,
    /// cap at full travel, and NO velocity term anywhere in the mapping.
    @Test func scrubFractionIsAMonotoneNonDecayingAccumulator() {
        #expect(SnapCommentTickerView.scrubFraction(forAccumulatedDistance: 0) == SnapCommentTickerView.scrubEngagementFloor)
        #expect(SnapCommentTickerView.scrubFraction(forAccumulatedDistance: 10_000) == SnapCommentTickerView.maxBlurFraction)

        var previous: CGFloat = -1
        for distance in stride(from: CGFloat(0), through: 600, by: 20) {
            let fraction = SnapCommentTickerView.scrubFraction(forAccumulatedDistance: distance)
            #expect(fraction >= previous) // can build or hold, never drop
            previous = fraction
        }
    }

    /// The accumulator sums |Δx|, not net translation: scrubbing forward
    /// then all the way back builds intensity instead of cancelling out.
    @Test func accumulatorSumsAbsoluteDeltasNotNetTranslation() {
        let ticker = makeTicker()
        ticker.setActive(true)
        ticker.beginScrub()
        ticker.applyScrubTranslation(-200)
        ticker.applyScrubTranslation(200) // net translation: zero
        ticker.endScrub(releaseVelocity: 1200)

        ticker.coastStep(now: CACurrentMediaTime() + 0.001)
        // 400pt of absolute travel ≥ blurDistanceScale → released at the cap.
        #expect(ticker.currentKineticFraction > SnapCommentTickerView.maxBlurFraction - 0.05)
    }

    // MARK: - Decay math

    @Test func coastVelocityRelaxesToDriftWithoutOvershoot() {
        let release: CGFloat = 800
        let drift: CGFloat = -26
        var previous = release
        for step in 1...40 {
            let velocity = SnapCommentTickerView.coastVelocity(
                release: release, steadyDrift: drift, elapsed: TimeInterval(step) * 0.05
            )
            #expect(velocity < previous) // monotonic toward drift
            #expect(velocity > drift) // never overshoots past steady state
            previous = velocity
        }
        let settled = SnapCommentTickerView.coastVelocity(release: release, steadyDrift: drift, elapsed: 10)
        #expect(abs(settled - drift) < 0.01)
    }

    @Test func coastVelocityStartsAtTheReleaseVelocity() {
        let velocity = SnapCommentTickerView.coastVelocity(release: -300, steadyDrift: -22, elapsed: 0)
        #expect(abs(velocity - -300) < 0.01)
    }
}
