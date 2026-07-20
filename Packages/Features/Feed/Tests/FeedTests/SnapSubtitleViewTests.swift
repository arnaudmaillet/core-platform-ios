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

    // MARK: - Author avatar

    /// The leading avatar (an `AvatarImageView`, i.e. a `UIImageView`).
    private func avatar(_ view: SnapSubtitleView) -> UIImageView? {
        view.subviews.compactMap { $0 as? UIImageView }.first
    }

    /// The avatar's one-shot entrance matches the first cue's kind — fade
    /// envelope or immediate clamp — and either way ends AT 1 and fills
    /// forwards: its hold is the page's visible lifetime.
    @Test func avatarEntranceMatchesTheCueEntranceKind() {
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

    /// The avatar carries author identity, so it rises whenever cues do —
    /// with the first cue, no longer gated on a comment count. An idle
    /// (never-activated) zone keeps it down.
    @Test func activationRaisesTheAvatarWithTheFirstCue() {
        let active = makeView([cue("a"), cue("b"), cue("c")])
        active.setActive(true)
        #expect(avatar(active)?.layer.animation(forKey: "subtitle-avatar") != nil)

        let idle = makeView([cue("a"), cue("b"), cue("c")])
        #expect(avatar(idle)?.layer.animation(forKey: "subtitle-avatar") == nil)
    }

    /// The alignment contract: the avatar LEADS the row and TOP-aligns to
    /// the pill's first line, with the pill flowing to its right — so a
    /// two-line cue keeps line two beside the avatar column (aligned with
    /// line one's leading edge, never wrapping under the circle).
    @Test func avatarTopAlignsWithFirstLineAndTextFlowsBeside() {
        let view = makeView([cue("a")])
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
            let circle = avatar(view)
            #expect(pill != nil && circle != nil)
            if let pill, let circle {
                #expect(circle.frame.minX == 0)                        // avatar leads the row
                #expect(abs(circle.frame.minY - pill.frame.minY) < 0.5) // top-aligned to line one
                #expect(pill.frame.minX > circle.frame.maxX)           // text flows to its right
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
