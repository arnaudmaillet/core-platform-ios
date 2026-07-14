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

    /// A page that already owns its cues (prefetched at dequeue, revisit)
    /// presents INSTANTLY on activation: during a swipe the pill is static
    /// content riding the cell — an entrance fade would be the pop-in the
    /// visibility seam exists to prevent.
    @Test func activationWithOwnedCuesPresentsInstantly() {
        let view = makeView([cue("a"), cue("b"), cue("c")])
        view.setActive(true)

        let animation = try! #require(cueAnimation(view))
        #expect(animation.values?.count == 2) // flat clamp at 1 — no ramp
        #expect((animation.values?.first as? NSNumber)?.doubleValue == 1)
        #expect(!animation.isRemovedOnCompletion)
    }

    /// Content landing while the page is already on screen announces
    /// itself: lead-in + fade entrance.
    @Test func cuesArrivingWhileVisibleFadeIn() {
        let view = SnapSubtitleView(frame: CGRect(x: 0, y: 0, width: 350, height: 50))
        view.setActive(true)
        view.setCues([cue("a"), cue("b"), cue("c")])

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

    // MARK: - Count bubble

    private func bubble(_ view: SnapSubtitleView) -> UIVisualEffectView? {
        view.subviews.compactMap { $0 as? UIVisualEffectView }.first
    }

    /// The bubble's one-shot entrance matches the first cue's kind — fade
    /// envelope or immediate clamp — and either way ends AT 1 and fills
    /// forwards: its hold is the page's visible lifetime.
    @Test func bubbleEntranceMatchesTheCueEntranceKind() {
        let fade = SnapSubtitleView.bubbleEntrance(fadingIn: true)
        #expect((fade.values as? [NSNumber])?.map(\.doubleValue) == [0, 0, 1])
        #expect(fade.fillMode == .forwards)
        #expect(!fade.isRemovedOnCompletion)
        let expected = SnapSubtitleView.leadInDelay + SnapSubtitleView.fadeDuration
        #expect(abs(fade.duration - expected) < 0.001)

        let instant = SnapSubtitleView.bubbleEntrance(fadingIn: false)
        #expect((instant.values as? [NSNumber])?.map(\.doubleValue) == [1, 1])
        #expect(instant.fillMode == .forwards)
        #expect(!instant.isRemovedOnCompletion)
    }

    @Test func activationRaisesTheBubbleOnlyWhenACountExists() {
        let counted = makeView([cue("a"), cue("b"), cue("c")])
        counted.setCommentCount(24)
        counted.setActive(true)
        #expect(bubble(counted)?.layer.animation(forKey: "subtitle-count") != nil)

        let uncounted = makeView([cue("a"), cue("b"), cue("c")])
        uncounted.setActive(true)
        #expect(bubble(uncounted)?.layer.animation(forKey: "subtitle-count") == nil)
    }

    /// The vertical alignment invariant: bubble and pill share the zone's
    /// bottom edge, so a two-line cue grows the pill upward while the
    /// bubble holds its ground — never centered, never at the top.
    @Test func bubbleBottomAlignsWithThePillAcrossLineWraps() {
        let view = makeView([cue("a")])
        view.setCommentCount(24)
        let oneLine = SubtitleCue(id: "one", text: "Short cue.")
        let twoLine = SubtitleCue(
            id: "two",
            text: "A deliberately much longer semantic comment that has no chance of fitting on a single rendered line at this width."
        )

        for probe in [oneLine, twoLine] {
            view.setCues([probe, cue("b"), cue("c")])
            view.setActive(true)
            view.layoutIfNeeded()
            let pill = view.subviews.compactMap { $0 as? UILabel }.first
            let chip = bubble(view)
            #expect(pill != nil && chip != nil)
            if let pill, let chip {
                #expect(abs(pill.frame.maxY - chip.frame.maxY) < 0.5)
                #expect(chip.frame.minX == 0) // bubble leads the row
                #expect(pill.frame.minX > chip.frame.maxX) // pill flows after it
            }
            view.setActive(false)
        }
    }

    @Test func countTextFormatsCompactly() {
        #expect(SnapSubtitleView.countText(12) == "12")
        #expect(SnapSubtitleView.countText(999) == "999")
        #expect(SnapSubtitleView.countText(1400) == "1.4k")
    }
}
