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
        #expect(contentLayers(view).allSatisfy { $0.opacity == 0 })
    }

    @Test func reuseResetClearsContentAndAnimation() {
        let view = makeView([cue("a"), cue("b"), cue("c")])
        view.setActive(true)

        view.reset()
        #expect(cueAnimation(view) == nil)
        #expect(view.isHidden)
        #expect(contentLayers(view).allSatisfy { $0.opacity == 0 })
    }

    @Test func emptyCueListKeepsTheZoneHidden() {
        let view = makeView([])
        view.setActive(true)
        #expect(view.isHidden)
        #expect(cueAnimation(view) == nil)
    }

    // MARK: - Author avatar

    /// The non-clipping wrapper that leads the row and anchors the avatar +
    /// badge.
    private func avatarContainer(_ view: SnapSubtitleView) -> UIView? {
        view.subviews.first { $0.accessibilityIdentifier == "subtitle-avatar-container" }
    }

    /// The leading avatar (an `AvatarImageView`, i.e. a `UIImageView`) —
    /// nested inside the wrapper.
    private func avatar(_ view: SnapSubtitleView) -> UIImageView? {
        avatarContainer(view)?.subviews.compactMap { $0 as? UIImageView }.first
    }

    /// The count badge, nested inside the wrapper.
    private func countBadge(_ view: SnapSubtitleView) -> UIView? {
        avatarContainer(view)?.subviews.first { $0.accessibilityIdentifier == "subtitle-count-badge" }
    }

    /// The cue-cycle content whose opacity rides the fade — pill, avatar,
    /// badge. The wrapper itself is a static layout anchor (opacity 1) and
    /// is deliberately excluded.
    private func contentLayers(_ view: SnapSubtitleView) -> [CALayer] {
        [view.subviews.compactMap { $0 as? UILabel }.first, avatar(view), countBadge(view)]
            .compactMap { $0?.layer }
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

    /// The fixed-anchor contract: the avatar WRAPPER is a ROCK-SOLID anchor
    /// at the zone's center — its frame is IDENTICAL whether the cue is one
    /// line or two — while the pill is the dynamic element, centered on the
    /// wrapper (so it expands symmetrically) and flowing off its trailing
    /// edge (line two beside the avatar, never under it).
    @Test func avatarBlockStaysFixedWhileTextCentersOnIt() throws {
        let view = makeView([cue("a")])
        let oneLine = SubtitleCue(id: "one", text: "Short cue.")
        let twoLine = SubtitleCue(
            id: "two",
            text: "A deliberately much longer semantic comment that has no chance of fitting on a single rendered line at this width."
        )

        var containerFrames: [CGRect] = []
        var badgeFrames: [CGRect] = []
        for probe in [oneLine, twoLine] {
            view.setCommentCount(24)
            view.setCues([probe, cue("b"), cue("c")])
            view.setActive(true)
            view.layoutIfNeeded()
            let pill = try #require(view.subviews.compactMap { $0 as? UILabel }.first)
            let container = try #require(avatarContainer(view))
            let badge = try #require(countBadge(view))
            #expect(container.frame.minX == 0)                          // wrapper leads the row
            #expect(abs(container.frame.midY - pill.frame.midY) < 0.5)  // pill centers on the wrapper
            #expect(pill.frame.minX > container.frame.maxX)             // text flows off the wrapper's edge
            // The avatar fills the wrapper exactly (its own round clip).
            let circle = try #require(avatar(view))
            #expect(circle.frame.size == container.bounds.size)
            containerFrames.append(container.frame)
            badgeFrames.append(view.convert(badge.frame, from: badge.superview))
            view.setActive(false)
        }

        // The whole avatar block — wrapper AND its overflowing badge — sits
        // at the EXACT same coordinates for a one-line and a two-line cue.
        #expect(containerFrames[0] == containerFrames[1])
        #expect(badgeFrames[0] == badgeFrames[1])
    }

    /// The count badge sits on the wrapper's BOTTOM-RIGHT corner and
    /// deliberately OVERFLOWS it (offset down-and-right past the avatar's
    /// bounds — the wrapper doesn't clip), carries the count, and rises with
    /// the first cue. A zero count keeps it hidden.
    @Test func countBadgeOverflowsTheAvatarBottomRight() throws {
        let view = makeView([cue("a"), cue("b"), cue("c")])
        view.setCommentCount(24)
        view.setActive(true)
        view.layoutIfNeeded()

        let container = try #require(avatarContainer(view))
        let badge = try #require(countBadge(view))
        let count = badge.subviews.compactMap { $0 as? UILabel }.first
        #expect(badge.isHidden == false)
        #expect(count?.text == "24")
        #expect(badge.layer.animation(forKey: "subtitle-badge") != nil) // rose with the cue
        #expect(container.clipsToBounds == false)                       // so the badge can bleed out
        // Bottom-right, bled PAST the avatar's bounds (in the wrapper's own
        // coordinate space its bounds are the avatar box).
        #expect(badge.frame.maxX > container.bounds.width)
        #expect(badge.frame.maxY > container.bounds.height)

        // A zero count keeps the badge down.
        let uncounted = makeView([cue("a"), cue("b"), cue("c")])
        uncounted.setCommentCount(0)
        uncounted.setActive(true)
        #expect(countBadge(uncounted)?.isHidden == true)
    }

    @Test func countTextFormatsCompactly() {
        #expect(SnapSubtitleView.countText(12) == "12")
        #expect(SnapSubtitleView.countText(999) == "999")
        #expect(SnapSubtitleView.countText(1400) == "1.4k")
    }
}
