import AVKit
import Testing
import UIKit
@testable import MediaPlayback

/// One floating-window controller per surface, for the surface's life (#483):
/// AVKit hangs an unretained helper off the sample-buffer layer, and a
/// controller released while its layer lived, then another made for it,
/// crashed the app on the next layout (the owner's device, 2026-11-06).
@MainActor
@Suite(.serialized, .exclusiveMediaWork)
struct PictureInPictureControllerTests {
    @Test func aSurfaceKeepsOneControllerForItsLife() {
        let surface = VideoRenderView()
        guard let first = surface.readiedPictureInPicture() else { return }
        #expect(surface.readiedPictureInPicture() === first)
        #expect(surface.pictureInPictureController === first)
    }
}
