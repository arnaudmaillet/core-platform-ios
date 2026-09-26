import AVFoundation
import Testing
import UIKit
@testable import MediaPlayback

/// The feed's sound: one surface heard at a time, whatever player ends up
/// behind it, under the app's `.ambient` session.
@MainActor
@Suite(.serialized, .exclusiveMediaWork)
struct AudibleSurfaceTests {
    private struct Passthrough: VideoSource {
        func playableURL(for url: URL) async throws -> URL { url }
    }

    private func controller() -> VideoPlaybackController {
        VideoPlaybackController(source: Passthrough(), poolSize: 2, capacity: 2)
    }

    private func surface() -> VideoRenderView {
        let view = VideoRenderView()
        view.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        return view
    }

    @Test func theAudibleSurfaceIsHeardAndTheOtherIsNot() async throws {
        let controller = controller()
        let file = try await ColourClipWriter.clip()
        let first = surface(), second = surface()
        await controller.play(file, in: first, scope: "first")
        await controller.play(file, in: second, scope: "second")
        defer { controller.stop(first); controller.stop(second) }

        controller.setAudibleSurface(first)
        #expect(controller.isMuted(in: first) == false)
        #expect(controller.isMuted(in: second) == true)

        controller.setAudibleSurface(second)
        #expect(controller.isMuted(in: first) == true, "the page scrolled past is still talking")
        #expect(controller.isMuted(in: second) == false)

        controller.setAudibleSurface(nil)
        #expect(controller.isMuted(in: second) == true, "nothing is audible, yet the last page is heard")
    }

    /// ⚠️ A FRESH BIND STARTS MUTED. The feed names the page before its clip
    /// has a player; whatever is bound there later must still be heard.
    @Test func aPlayerBoundLaterToTheAudibleSurfaceIsHeard() async throws {
        let controller = controller()
        let file = try await ColourClipWriter.clip()
        let view = surface()
        controller.setAudibleSurface(view)
        await controller.play(file, in: view)
        defer { controller.stop(view) }

        #expect(controller.isMuted(in: view) == false)
    }

    /// ⚠️ UNDER `.ambient`: a feed that starts talking on its own respects
    /// the ring switch — unlike `setMuted`, which asks for `.playback`.
    @Test func theFeedsSoundLeavesTheSessionAmbient() async throws {
        let controller = controller()
        let file = try await ColourClipWriter.clip()
        let view = surface()
        await controller.play(file, in: view)
        defer { controller.stop(view); controller.setAudibleSurface(nil) }

        controller.setAudibleSurface(view)
        #expect(controller.isMuted(in: view) == false)
        #expect(AVAudioSession.sharedInstance().category == .ambient)
    }

    /// A clip somebody asked to hear by name keeps its sound when the
    /// audible surface moves on.
    @Test func movingOnDoesNotSilenceAClipHeardByName() async throws {
        let controller = controller()
        let file = try await ColourClipWriter.clip()
        let first = surface(), second = surface()
        await controller.play(file, in: first, scope: "first")
        await controller.play(file, in: second, scope: "second")
        defer { controller.stop(first); controller.stop(second) }

        controller.setAudibleSurface(first)
        controller.setMuted(false, in: first)
        controller.setAudibleSurface(second)
        #expect(controller.isMuted(in: first) == false)
    }
}
