import Testing
import UIKit
@testable import Feed

/// The composer's field answers a touch natively (#730): interactive Liquid
/// Glass, as the avatar bubble beside it already was.
@MainActor
struct ComposerGlassTests {
    @Test func theComposerFieldIsInteractiveGlass() {
        let bar = CommentsInputBar()
        // The glass is made as the bar joins a window.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = true
        window.addSubview(bar)
        let effect = (bar.debugField as? UIVisualEffectView)?.effect as? UIGlassEffect
        #expect(effect != nil, "the field is not glass")
        #expect(effect?.isInteractive == true, "the field's glass has no native press response")
    }
}
