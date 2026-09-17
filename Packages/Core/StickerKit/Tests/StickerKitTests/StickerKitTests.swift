import Lottie
import Testing
@testable import StickerKit

/// The skeleton's one promise: the package links Lottie, and a view built with
/// its on-screen engine really uses Core Animation.
@MainActor
struct StickerKitTests {
    @Test func anOnScreenStickerPlaysOnCoreAnimation() {
        let view = LottieAnimationView(
            configuration: LottieConfiguration(renderingEngine: StickerKit.onScreenEngine)
        )
        #expect(view.configuration.renderingEngine == .coreAnimation)
    }
}
