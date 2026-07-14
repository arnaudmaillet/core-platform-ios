import Testing
import UIKit
@testable import Feed

private func cue(_ id: String, at: TimeInterval? = nil) -> SubtitleCue {
    SubtitleCue(id: id, text: "A longer semantic thought \(id) worth reading.", at: at)
}

@MainActor
struct SnapSubtitleViewTests {
    private func makeView(_ cues: [SubtitleCue]) -> SnapSubtitleView {
        let view = SnapSubtitleView(frame: CGRect(x: 0, y: 0, width: 350, height: 50))
        view.setCues(cues)
        return view
    }

    private func cueAnimation(_ view: SnapSubtitleView) -> CAKeyframeAnimation? {
        view.subviews
            .compactMap { $0.layer.animation(forKey: "subtitle-cue") as? CAKeyframeAnimation }
            .first
    }

    // MARK: - Transition planning

    /// v1's even pacing carries no timeline anchors — every handoff keeps
    /// the subtitle idiom, regardless of how dense the cue list is.
    @Test func untimestampedCuesAlwaysFade() {
        let plan = SnapSubtitleView.plannedTransitions(for: [cue("a"), cue("b"), cue("c")])
        #expect(plan == [.fade, .fade, .fade])
    }

    /// The threshold safety net: neighbors closer than the flicker floor
    /// hard-cut. The wrap-around restart still fades — the loop rejoining
    /// its start is a new pass, not a dense neighbor.
    @Test func denseTimestampsHardCutExceptTheWrapRestart() {
        let plan = SnapSubtitleView.plannedTransitions(
            for: [cue("a", at: 10.0), cue("b", at: 10.2), cue("c", at: 10.4)]
        )
        #expect(plan == [.cut, .cut, .fade])
    }

    @Test func sparseTimestampsKeepTheFadeIdiom() {
        let plan = SnapSubtitleView.plannedTransitions(
            for: [cue("a", at: 5.0), cue("b", at: 12.0), cue("c", at: 30.0)]
        )
        #expect(plan == [.fade, .fade, .fade])
    }

    /// A delta of exactly the threshold can breathe the full dark cycle —
    /// the cut applies strictly below it. Mixed timestamp presence (either
    /// side unanchored) also fades: density is unknowable there.
    @Test func thresholdIsExclusiveAndNeedsBothAnchors() {
        let boundary = SnapSubtitleView.plannedTransitions(
            for: [cue("a", at: 10.0), cue("b", at: 10.0 + SnapSubtitleView.hardCutThreshold)]
        )
        #expect(boundary == [.fade, .fade])

        let mixed = SnapSubtitleView.plannedTransitions(
            for: [cue("a", at: 10.0), cue("b"), cue("c", at: 10.1)]
        )
        #expect(mixed == [.fade, .fade, .fade])
    }

    // MARK: - Segment envelopes

    /// Fade-in → hold → fade-out: five keyframes, normally removed, ending
    /// at the invisible model value.
    @Test func fadeHandoffsRunTheFullEnvelope() {
        let view = makeView([cue("a"), cue("b"), cue("c")])
        view.setActive(true)

        let animation = try! #require(cueAnimation(view))
        #expect(animation.values?.count == 5)
        #expect(animation.isRemovedOnCompletion)
        let expected = SnapSubtitleView.interCueGap + 2 * SnapSubtitleView.fadeDuration
            + SnapSubtitleView.holdDuration
        #expect(abs(animation.duration - expected) < 0.001)
    }

    /// A cue whose successor is packed against it ends AT full opacity and
    /// fills forwards — the pill must never dip to the model value while
    /// the completion swaps the text in.
    @Test func cutExitsEndAtFullOpacityAndFillForwards() {
        let view = makeView([cue("a", at: 10.0), cue("b", at: 10.2), cue("c", at: 30.0)])
        view.setActive(true)

        let animation = try! #require(cueAnimation(view))
        #expect(animation.values?.count == 4) // [0, 0, 1, 1] — no closing fade
        #expect((animation.values?.last as? NSNumber)?.floatValue == 1)
        #expect(animation.fillMode == .forwards)
        #expect(!animation.isRemovedOnCompletion)
    }

    /// Deactivation must clear filled segments too — a fill-forwards pill
    /// outliving its page would be the stranded-content bug the model-at-0
    /// doctrine exists to prevent.
    @Test func deactivationRemovesFilledSegments() {
        let view = makeView([cue("a", at: 10.0), cue("b", at: 10.2), cue("c", at: 30.0)])
        view.setActive(true)
        #expect(cueAnimation(view) != nil)

        view.setActive(false)
        #expect(cueAnimation(view) == nil)
        #expect(view.subviews.allSatisfy { $0.layer.opacity == 0 })
    }
}
