import CoreStorage
import Testing
import UIKit
@testable import Feed

/// #560: the comment surfaces on a blur, behind `-comment-blur`. Off is
/// today's wash, unchanged; on, the blur follows the wash's own curves.
@MainActor
@Suite(.serialized)
struct CommentBlurTests {
    private func hosting(_ body: (UIWindow) async throws -> Void) async rethrows {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 100))
        window.isHidden = false
        defer {
            window.subviews.forEach { $0.removeFromSuperview() }
            window.isHidden = true
            window.layoutIfNeeded()
        }
        try await body(window)
    }

    @Test func theFlagIsReadFromTheLaunchArguments() {
        #expect(CommentBlur.isEnabled(arguments: ["app", "-comment-blur"]))
        #expect(!CommentBlur.isEnabled(arguments: ["app"]))
        #expect(!CommentBlur.isEnabled(arguments: ["app", "-comment-blurry"]))
    }

    /// The pill's strength is the viewer's fill over its ceiling. (The band
    /// no longer uses the blur flag: its letters wear an outline, #2339.)
    @Test func thePillsFillMapsOntoTheBlursStrength() {
        #expect(CommentBlur.pillStrength(fill: 0) == 0)
        #expect(abs(CommentBlur.pillStrength(fill: 0.45) - 0.5) < 0.001)
        #expect(CommentBlur.pillStrength(fill: 0.9) == 1)
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
