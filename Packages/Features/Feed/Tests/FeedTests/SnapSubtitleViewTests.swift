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

    // MARK: - Segment envelopes

    /// The first appearance: dark lead-in, fade-in, then clamped at full
    /// opacity until the successor arrives — persistence means no segment
    /// ever closes back to 0.
    @Test func firstSegmentFadesInAndFillsForwards() {
        let animation = SnapSubtitleView.segmentAnimation(fadingIn: true)
        #expect((animation.values as? [NSNumber])?.map(\.doubleValue) == [0, 0, 1, 1])
        #expect(animation.fillMode == .forwards)
        #expect(!animation.isRemovedOnCompletion)
        let expected = SnapSubtitleView.leadInDelay + SnapSubtitleView.fadeDuration
            + SnapSubtitleView.cueInterval
        #expect(abs(animation.duration - expected) < 0.001)
    }

    /// A handoff segment is nothing but the successor's arrival clock: flat
    /// full opacity for one interval, filled forwards so the pill never dips
    /// while the completion swaps the text.
    @Test func handoffSegmentsHoldFullOpacityForOneInterval() {
        let animation = SnapSubtitleView.segmentAnimation(fadingIn: false)
        #expect((animation.values as? [NSNumber])?.map(\.doubleValue) == [1, 1])
        #expect(animation.fillMode == .forwards)
        #expect(!animation.isRemovedOnCompletion)
        #expect(abs(animation.duration - SnapSubtitleView.cueInterval) < 0.001)
    }

    // MARK: - Lifecycle

    @Test func activationStartsTheFadeInSegment() {
        let view = makeView([cue("a"), cue("b"), cue("c")])
        view.setActive(true)

        let animation = try! #require(cueAnimation(view))
        #expect(animation.values?.count == 4) // the fade-in envelope
        #expect(!animation.isRemovedOnCompletion)
    }

    /// The persistent pill's ONLY exits: deactivation (swipe, playback
    /// stop) and reuse must clear the filled segment and drop the layer to
    /// its invisible model value — a fill-forwards pill outliving its page
    /// would be the stranded-content bug the model-at-0 doctrine prevents.
    @Test func deactivationRemovesTheFilledSegment() {
        let view = makeView([cue("a"), cue("b"), cue("c")])
        view.setActive(true)
        #expect(cueAnimation(view) != nil)

        view.setActive(false)
        #expect(cueAnimation(view) == nil)
        #expect(view.subviews.allSatisfy { $0.layer.opacity == 0 })
    }

    @Test func reuseResetClearsContentAndAnimation() {
        let view = makeView([cue("a"), cue("b"), cue("c")])
        view.setActive(true)

        view.reset()
        #expect(cueAnimation(view) == nil)
        #expect(view.isHidden)
        #expect(view.subviews.allSatisfy { $0.layer.opacity == 0 })
    }

    @Test func emptyCueListKeepsTheZoneHidden() {
        let view = makeView([])
        view.setActive(true)
        #expect(view.isHidden)
        #expect(cueAnimation(view) == nil)
    }
}
