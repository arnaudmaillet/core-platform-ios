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

/// What a surface answers when asked for a PICTURE of itself.
///
/// A video page had no answer at all, and the nil travelled: a transition that
/// carries the departing page's picture — so the media scales with its window
/// instead of being clipped by it — got nothing from a video and fell back to
/// clipping the live page. The frame is retained already; the gap was that
/// nothing could ask.
@MainActor
struct VideoRenderViewStillTests {
    private func picture() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    /// Nothing attached and nothing to show: genuinely no picture, and the
    /// callers are all written around that nil.
    @Test func anEmptySurfaceHasNoStill() {
        #expect(VideoRenderView().currentStill == nil)
    }

    /// ⚠️ THE POSTER IS NOT A LESSER ANSWER. Before the first frame it is what
    /// the surface is literally drawing, and under `-avplayer-render` — no
    /// renderer, so no retained buffer — it is the whole answer.
    @Test func aSurfaceShowingItsPosterAnswersWithIt() {
        let view = VideoRenderView()
        let poster = picture()
        view.setPoster(poster)

        #expect(view.currentStill === poster)
    }

    /// Cleared with the poster: an answer that outlived the picture it was
    /// about would hand a stale frame to the next flight.
    @Test func clearingThePosterClearsTheStill() {
        let view = VideoRenderView()
        view.setPoster(picture())
        view.setPoster(nil)

        #expect(view.currentStill == nil)
    }
}

