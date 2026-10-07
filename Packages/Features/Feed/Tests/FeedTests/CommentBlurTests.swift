import CoreStorage
import Testing
import UIKit
@testable import Feed

/// #560: the comment surfaces on a blur, behind `-comment-blur`. Off is
/// today's wash, unchanged; on, the blur follows the wash's own curves.
@MainActor
@Suite(.serialized)
struct CommentBlurTests {
    private let bandWidth: CGFloat = 390

    private func hosting(_ body: (UIWindow) async throws -> Void) async rethrows {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: bandWidth, height: 100))
        window.isHidden = false
        defer {
            window.subviews.forEach { $0.removeFromSuperview() }
            window.isHidden = true
            window.layoutIfNeeded()
        }
        try await body(window)
    }

    private func makeTicker(blur: Bool, in window: UIWindow) -> SnapCommentTickerView {
        let ticker = SnapCommentTickerView(frame: CGRect(x: 0, y: 0, width: bandWidth, height: 69))
        ticker.usesBlur = blur
        ticker.setComments((0..<12).map { TickerCommentModel(id: "r\($0)", text: "GG 🔥 \($0)") })
        window.addSubview(ticker)
        return ticker
    }

    @Test func theFlagIsReadFromTheLaunchArguments() {
        #expect(CommentBlur.isEnabled(arguments: ["app", "-comment-blur"]))
        #expect(!CommentBlur.isEnabled(arguments: ["app"]))
        #expect(!CommentBlur.isEnabled(arguments: ["app", "-comment-blurry"]))
    }

    /// The band's strength is the wash's opacity over its ceiling: the larger
    /// of the interaction and the resting level, clamped to 0…1.
    @Test func theWashsOpacityMapsOntoTheBlursStrength() {
        let ceiling = SnapCommentTickerView.maxBackdropOpacity
        #expect(CommentBlur.bandStrength(fraction: 0, resting: 0, ceiling: ceiling) == 0)
        #expect(CommentBlur.bandStrength(fraction: ceiling, resting: 0, ceiling: ceiling) == 1)
        #expect(abs(CommentBlur.bandStrength(fraction: 0.2, resting: 0.39, ceiling: ceiling) - 0.6) < 0.001,
                "the resting level wins when it is higher")
        #expect(CommentBlur.bandStrength(fraction: 2, resting: 0, ceiling: ceiling) == 1)
        #expect(CommentBlur.pillStrength(fill: 0) == 0)
        #expect(abs(CommentBlur.pillStrength(fill: 0.45) - 0.5) < 0.001)
        #expect(CommentBlur.pillStrength(fill: 0.9) == 1)
    }

    /// Off: the black wash, exactly as before, and no blur view at all.
    @Test func withTheFlagOffTheWashIsUnchanged() async throws {
        await hosting { window in
            let ticker = makeTicker(blur: false, in: window)
            ticker.setActive(true)
            ticker.beginScrub()
            ticker.applyScrubTranslation(-400)
            ticker.endScrub(releaseVelocity: 1200)
            ticker.coastStep(now: ticker.coastStartTime + 0.001)
            #expect(abs(ticker.currentBackdropOpacity - ticker.currentKineticFraction) < 0.001)
            #expect(ticker.currentBlurStrength == 0)
            #expect(!ticker.subviews.contains { $0.accessibilityIdentifier == "ticker-kinetic-blur" })
        }
    }

    /// On: the blur grows with the scrub's curve, the wash stays hidden, and
    /// after the coast hands over the dismissal relaxes it to rest.
    @Test func withTheFlagOnTheBlurFollowsTheWashsCurve() async throws {
        try await hosting { window in
            let ticker = makeTicker(blur: true, in: window)
            ticker.setActive(true)
            ticker.beginScrub()
            ticker.applyScrubTranslation(-400)
            ticker.endScrub(releaseVelocity: 1200)
            ticker.coastStep(now: ticker.coastStartTime + 0.001)
            let expected = CommentBlur.bandStrength(
                fraction: ticker.currentKineticFraction, resting: 0, ceiling: SnapCommentTickerView.maxBackdropOpacity
            )
            #expect(abs(ticker.currentBlurStrength - expected) < 0.001)
            #expect(ticker.currentBlurStrength > 0.9)
            #expect(ticker.currentBackdropOpacity == 0, "the black wash stays out")

            ticker.coastStep(now: ticker.coastStartTime + 30) // handover → dismissal
            #expect(ticker.currentKineticFraction == 0)
            for _ in 0..<40 where ticker.currentBlurStrength > 0 {
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(ticker.currentBlurStrength == 0, "relaxed back to rest (none by default)")
        }
    }

    /// The `KineticAnimatorBag` trap: a band released mid-drag, with its
    /// paused animator engaged, must not throw on deallocation.
    @Test func aBandReleasedMidDragDoesNotThrow() async throws {
        try await hosting { window in
            do {
                let ticker = makeTicker(blur: true, in: window)
                ticker.setActive(true)
                ticker.beginScrub()
                ticker.applyScrubTranslation(-200)
                ticker.endScrub(releaseVelocity: 1200)
                ticker.coastStep(now: ticker.coastStartTime + 0.001) // mid-coast
                #expect(ticker.currentBlurStrength > 0, "the animator is engaged")
                ticker.removeFromSuperview()
            }
            // The bag finishes orphaned animators on the next main turn.
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The pill reads on a blur at the viewer's fill strength, its own black
    /// fill cleared, and the blur goes with the cue cycle.
    @Test func withTheFlagOnThePillReadsOnABlur() async throws {
        await hosting { window in
            let view = SnapSubtitleView(frame: CGRect(x: 0, y: 0, width: 350, height: 50))
            view.usesBlur = true
            window.addSubview(view)
            view.setCues([SubtitleCue(id: "a", text: "A longer semantic thought worth reading.", at: nil)])
            view.setActive(true) // an instant entrance: no fade, so no ramp
            #expect(abs(view.pillBlurStrength - CommentBlur.pillStrength(fill: SubtitlePillLabel.fillOpacity)) < 0.001)
            let label = view.subviews.compactMap { $0 as? SubtitlePillLabel }.first
            #expect(label?.layer.backgroundColor == UIColor.clear.cgColor, "the black fill is gone")

            view.setActive(false)
            #expect(view.pillBlurStrength == 0)
        }
    }

    /// Off: the pill keeps its black fill and has no blur.
    @Test func withTheFlagOffThePillIsUnchanged() async {
        await hosting { window in
            let view = SnapSubtitleView(frame: CGRect(x: 0, y: 0, width: 350, height: 50))
            view.usesBlur = false
            window.addSubview(view)
            view.setCues([SubtitleCue(id: "a", text: "A longer semantic thought worth reading.", at: nil)])
            view.setActive(true)
            #expect(view.pillBlurStrength == 0)
            #expect(!view.subviews.contains { $0.accessibilityIdentifier == "subtitle-pill-blur" })
        }
    }
}
