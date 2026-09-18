import QuartzCore
import Testing
import UIKit
@testable import Upload

/// The play/pause flash's own curves — the editor's tests pin WHICH state is
/// flashed; these pin that it can be SEEN.
@MainActor
struct MediaPlaybackFlashTests {
    /// The fade's starting opacity, as the render tree will play it.
    private func fadeStart(of flash: MediaPlaybackFlashView) -> Double? {
        guard let fade = flash.layer.animation(forKey: "opacity") as? CABasicAnimation else { return nil }
        return (fade.fromValue as? NSNumber)?.doubleValue
    }

    /// ⚠️ **UNDER REDUCE MOTION, EVERY FLASH STARTS VISIBLE — NOT ONLY THE
    /// FIRST.** The fade read its from-value off the presentation layer, which
    /// after one flash holds a committed 0; the next flash then faded 0 → 0.
    @Test func underReduceMotionASecondFlashIsSeenToo() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        let flash = MediaPlaybackFlashView()
        flash.reducesMotion = { true }
        window.addSubview(flash)

        flash.flash(paused: true, at: CGPoint(x: 195, y: 400))
        #expect(fadeStart(of: flash) == 1, "guard: the first flash starts at \(String(describing: fadeStart(of: flash)))")
        // The first flash runs its course: nothing in flight, 0 committed.
        flash.layer.removeAllAnimations()
        CATransaction.flush()

        flash.flash(paused: false, at: CGPoint(x: 195, y: 400))

        #expect(fadeStart(of: flash) == 1, "the second flash fades from \(String(describing: fadeStart(of: flash)))")
    }
}
