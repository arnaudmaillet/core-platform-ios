import AVFoundation
import MediaPlayer
import Testing
import UIKit
@testable import MediaPlayback

/// Background Play (#483): the clip being heard keeps playing off screen,
/// under a `.playback` session, with the Lock Screen's info — and only that
/// clip, and only while it is heard.
@MainActor
@Suite(.serialized, .exclusiveMediaWork)
struct BackgroundPlaybackTests {
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

    private let info = NowPlayingInfo(title: "Golden hour on the Seine", artist: "Ava Moreau")

    @Test func theHeardClipGoesOnPlayingWithTheLockScreensInfo() async throws {
        let controller = controller()
        let file = try await ColourClipWriter.clip()
        let view = surface()
        await controller.play(file, in: view)
        defer { controller.endBackgroundPlayback(); controller.stop(view); controller.setAudibleSurface(nil) }
        controller.setAudibleSurface(view)

        #expect(controller.continueInBackground(view, nowPlaying: info))
        #expect(controller.isPlayingInBackground)
        #expect(AVAudioSession.sharedInstance().category == .playback, "an .ambient session goes quiet in the background")
        let shown = MPNowPlayingInfoCenter.default().nowPlayingInfo
        #expect(shown?[MPMediaItemPropertyTitle] as? String == "Golden hour on the Seine")
        #expect(shown?[MPMediaItemPropertyArtist] as? String == "Ava Moreau")
        #expect(MPRemoteCommandCenter.shared().skipForwardCommand.isEnabled)

        controller.endBackgroundPlayback()
        #expect(!controller.isPlayingInBackground)
        #expect(AVAudioSession.sharedInstance().category == .ambient, "back on screen, the feed mixes again")
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil)
        #expect(!MPRemoteCommandCenter.shared().skipForwardCommand.isEnabled)
    }

    /// A silent clip is not listening: nothing is kept alive for it.
    @Test func aMutedClipIsNotKeptAlive() async throws {
        let controller = controller()
        let file = try await ColourClipWriter.clip()
        let view = surface()
        await controller.play(file, in: view)
        defer { controller.stop(view) }

        #expect(!controller.continueInBackground(view, nowPlaying: info))
        #expect(!controller.isPlayingInBackground)
        #expect(AVAudioSession.sharedInstance().category == .ambient)
    }

    /// A clip the viewer paused stays paused, and off the Lock Screen.
    @Test func aPausedClipIsNotKeptAlive() async throws {
        let controller = controller()
        let file = try await ColourClipWriter.clip()
        let view = surface()
        await controller.play(file, in: view)
        defer { controller.stop(view); controller.setAudibleSurface(nil) }
        controller.setAudibleSurface(view)
        controller.setPaused(true, in: view)

        #expect(!controller.continueInBackground(view, nowPlaying: info))
    }

    /// The Lock Screen's pause and play go through the surface, and skip
    /// moves the clip.
    @Test func theLockScreensControlsMoveTheClip() async throws {
        let controller = controller()
        let file = try await ColourClipWriter.clip()
        let view = surface()
        await controller.play(file, in: view)
        defer { controller.endBackgroundPlayback(); controller.stop(view); controller.setAudibleSurface(nil) }
        controller.setAudibleSurface(view)
        #expect(controller.continueInBackground(view, nowPlaying: info))

        controller.backgroundSetPaused(true)
        #expect(controller.watchedPlayer(in: view)?.timeControlStatus == .paused)
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)

        controller.backgroundSkip(by: -VideoPlaybackController.backgroundSkipInterval)
        let elapsed = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double
        #expect(elapsed == 0, "skipping back past the start lands on the start")

        controller.backgroundSetPaused(false)
        #expect(controller.watchedPlayer(in: view)?.timeControlStatus != .paused)
    }

    /// ⚠️ MediaPlayer renders the cover on its own queue. Built inside the main
    /// actor, the handler trapped there and took the app down the moment a
    /// cover was published.
    @Test func publishingACoverIsSafeOffTheMainActor() async throws {
        let controller = controller()
        let file = try await ColourClipWriter.clip()
        let view = surface()
        await controller.play(file, in: view)
        defer { controller.endBackgroundPlayback(); controller.stop(view); controller.setAudibleSurface(nil) }
        controller.setAudibleSurface(view)
        #expect(controller.continueInBackground(view, nowPlaying: info))

        let cover = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        controller.setNowPlayingArtwork(cover)
        // MediaPlayer pushes the dictionary, and asks for the cover's
        // pixels, a moment later on its own queue.
        try await Task.sleep(for: .milliseconds(500))
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] != nil)
    }

    /// Picture in Picture (#483): readying a clip needs a device that can
    /// show the window. Where it can't (this simulator says so), nothing is
    /// readied and the feed's session stays `.ambient`; where it can, the
    /// session becomes `.playback` until the clip is let go.
    @Test func readyingPictureInPictureFollowsWhatTheDeviceCan() async throws {
        let controller = controller()
        let file = try await ColourClipWriter.clip()
        let view = surface()
        await controller.play(file, in: view)
        defer { controller.armPictureInPicture(for: nil); controller.stop(view) }

        let armed = controller.armPictureInPicture(for: view)
        #expect(armed == VideoPlaybackController.supportsPictureInPicture)
        #expect(controller.isPictureInPictureArmed == armed)
        #expect(AVAudioSession.sharedInstance().category == (armed ? .playback : .ambient))
        #expect(!controller.isPictureInPictureActive)

        controller.armPictureInPicture(for: nil)
        #expect(!controller.isPictureInPictureArmed)
        #expect(AVAudioSession.sharedInstance().category == .ambient)
    }

    /// While the window is up the app is off screen, where the display link
    /// does not fire: a timer paces the renderers instead, and only then.
    @Test func theWindowGetsFramesWithoutTheDisplay() {
        let clock = VideoFrameClock.shared
        defer { clock.pacesWithoutDisplay = false }
        #expect(!clock.isPacingWithoutDisplay)
        clock.pacesWithoutDisplay = true
        #expect(clock.isPacingWithoutDisplay)
        clock.pacesWithoutDisplay = false
        #expect(!clock.isPacingWithoutDisplay)
    }

    /// A clip given back to the pool leaves the Lock Screen with it.
    @Test func stoppingTheClipEndsBackgroundPlayback() async throws {
        let controller = controller()
        let file = try await ColourClipWriter.clip()
        let view = surface()
        await controller.play(file, in: view)
        controller.setAudibleSurface(view)
        #expect(controller.continueInBackground(view, nowPlaying: info))

        controller.stop(view)
        controller.setAudibleSurface(nil)
        #expect(!controller.isPlayingInBackground)
        #expect(AVAudioSession.sharedInstance().category == .ambient)
    }
}
