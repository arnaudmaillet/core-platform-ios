import DesignSystem
import Testing
import UIKit
@testable import PostGrid

/// The paused clip's play mark comes and goes with the app's one appear
/// motion (#1151): a bounce in on pause, a scale out on play, a fade both
/// ways under Reduce Motion — and a quick pause → play → pause reverses
/// rather than jumps.
@MainActor
struct PausedClipMarkMotionTests {
    private func hosted(reduced: Bool = false) -> (PausedClipMarkView, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        let mark = PausedClipMarkView()
        mark.reducesMotion = { reduced }
        mark.frame = window.bounds
        window.addSubview(mark)
        window.isHidden = false
        return (mark, window)
    }

    private func settle(until condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// The fade's from-value is the staged 0, not the presentation's 1 —
    /// otherwise it runs end to end, invisible (`uiview-animate-from-value-trap`).
    private func opacityFrom(_ view: UIView) -> Double? {
        let key = view.layer.animationKeys()?.first { $0.contains("opacity") }
        return (key.flatMap { view.layer.animation(forKey: $0) } as? CABasicAnimation)?.fromValue as? Double
    }

    @Test(arguments: [false, true])
    func pausingBouncesInOrFades(_ reduced: Bool) {
        let (mark, window) = hosted(reduced: reduced)
        defer { window.isHidden = true }
        mark.setVisible(true)
        #expect(mark.motions == [reduced ? .fadeIn : .bounceIn])
        #expect(mark.isShowing && !mark.isHidden, "showing from the start of the appear")
        #expect(opacityFrom(mark) == 0, "the fade starts from the screen's value, not the staged 0")
    }

    @Test(arguments: [false, true])
    func playingScalesOutOrFadesThenHides(_ reduced: Bool) async {
        let (mark, window) = hosted(reduced: reduced)
        defer { window.isHidden = true }
        mark.setVisible(true, animated: false)
        mark.setVisible(false)
        #expect(mark.motions == [reduced ? .fadeOut : .scaleOut])
        #expect(!mark.isShowing)
        #expect(await settle { mark.isHidden }, "hidden at the end of the disappear")
        #expect(mark.transform == .identity && mark.alpha == 1, "it leaves no scale behind for the next pause")
    }

    /// Three quick taps: each reverses the one before, and the last one wins.
    @Test func quickTapsReverseAndTheLastWins() async {
        let (mark, window) = hosted()
        defer { window.isHidden = true }
        mark.setVisible(true)
        mark.setVisible(false)
        mark.setVisible(true)
        #expect(mark.motions == [.bounceIn, .scaleOut, .bounceIn])
        try? await Task.sleep(for: .milliseconds(600))
        #expect(!mark.isHidden, "the reversed disappear hid the mark anyway")
        #expect(mark.isShowing)
    }

    @Test func theSameAskIsANoOp() {
        let (mark, window) = hosted()
        defer { window.isHidden = true }
        mark.setVisible(true)
        mark.setVisible(true)
        #expect(mark.motions == [.bounceIn], "a reconcile restarted the motion")
    }

    /// A rebind clears the mark at once, mid-motion or not.
    @Test func unanimatedIsInstant() {
        let (mark, window) = hosted()
        defer { window.isHidden = true }
        mark.setVisible(true)
        mark.setVisible(false, animated: false)
        #expect(mark.isHidden && !mark.isShowing)
        #expect(mark.layer.animationKeys() == nil)
        #expect(mark.transform == .identity && mark.alpha == 1)
    }
}
