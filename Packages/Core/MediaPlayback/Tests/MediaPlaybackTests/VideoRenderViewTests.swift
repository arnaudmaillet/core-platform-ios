import Testing
import UIKit
@testable import MediaPlayback

@MainActor
struct VideoRenderViewTests {
    @Test func posterShowsWhileNoFrameIsReadyAndClearsWhenRemoved() {
        let view = VideoRenderView()
        // No poster set yet → nothing to show.
        #expect(view.isPosterVisible == false)

        // With no player attached the layer is never ready, so a set poster shows.
        view.setPoster(UIImage())
        #expect(view.isPosterVisible == true)

        // Clearing the poster hides it.
        view.setPoster(nil)
        #expect(view.isPosterVisible == false)
    }
}
