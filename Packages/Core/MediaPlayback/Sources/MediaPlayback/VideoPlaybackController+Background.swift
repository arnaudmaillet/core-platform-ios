import AVFoundation
import MediaPlayer
import UIKit

/// What the Lock Screen and Control Center show for a clip heard in the
/// background (#483).
public struct NowPlayingInfo: Equatable, Sendable {
    public var title: String
    public var artist: String

    public init(title: String, artist: String) {
        self.title = title
        self.artist = artist
    }
}

extension VideoPlaybackController {
    /// How far the Lock Screen's skip buttons move.
    public static let backgroundSkipInterval: Double = 10

    /// Background Play (#483): keeps the clip heard in `surface` playing once
    /// the app has left the screen, and puts it on the Lock Screen with play,
    /// pause and ±10 s controls. Returns whether a player took it.
    ///
    /// ⚠️ **ONLY FOR A CLIP THE VIEWER IS ALREADY HEARING.** The caller (the
    /// feed) asks this only when its owner page is audible and Background Play
    /// is on; App Review expects background audio to be real listening, not a
    /// silent player kept alive.
    ///
    /// ⚠️ **THE SESSION BECOMES `.playback`, AND THAT STOPS OTHER APPS' AUDIO.**
    /// `.ambient` is silenced in the background, so there is no mixable way to
    /// keep sound going, and a mixable session gets no Now Playing either.
    /// `endBackgroundPlayback` hands the session back to `.ambient`.
    @discardableResult
    public func continueInBackground(_ surface: VideoRenderView, nowPlaying: NowPlayingInfo) -> Bool {
        guard let player = watchedPlayer(in: surface), !player.isMuted, player.currentItem != nil,
              player.timeControlStatus != .paused else { return false }
        backgroundSurface = surface
        backgroundPlayer = player
        // An AVPlayer that renders through no layer of its own (the sample-
        // buffer path) would be paused by the system's automatic policy.
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        settleAudioSession()
        try? AVAudioSession.sharedInstance().setActive(true)
        installRemoteCommands()
        publishNowPlaying(nowPlaying, artwork: nil)
        #if DEBUG
        traceSound("background start \(VideoProducerLog.name(player)) session=\(AVAudioSession.sharedInstance().category.rawValue)")
        #endif
        return true
    }

    /// Adds the cover once it has loaded; ignored when nothing plays in the
    /// background any more.
    public func setNowPlayingArtwork(_ image: UIImage) {
        guard backgroundPlayer != nil else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = Self.artwork(image)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Whether a clip is being kept playing in the background.
    public var isPlayingInBackground: Bool { backgroundPlayer != nil }

    /// Back on screen, or the clip went away: the Lock Screen forgets it and
    /// the session returns to `.ambient`. Safe to call when nothing plays.
    public func endBackgroundPlayback() {
        guard let player = backgroundPlayer else { return }
        player.audiovisualBackgroundPlaybackPolicy = .automatic
        backgroundPlayer = nil
        backgroundSurface = nil
        removeRemoteCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        settleAudioSession()
        #if DEBUG
        traceSound("background end")
        #endif
    }

    // MARK: - Lock Screen

    private func publishNowPlaying(_ nowPlaying: NowPlayingInfo, artwork: UIImage?) {
        guard let player = backgroundPlayer, let item = player.currentItem else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlaying.title,
            MPMediaItemPropertyArtist: nowPlaying.artist,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        let duration = item.duration.seconds
        if duration.isFinite, duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        refreshPlaybackPosition(in: &info, of: player)
        if let artwork {
            info[MPMediaItemPropertyArtwork] = Self.artwork(artwork)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// The position and rate, so the Lock Screen's progress bar runs on its
    /// own between commands.
    private func refreshPlaybackPosition(in info: inout [String: Any], of player: AVPlayer) {
        let elapsed = player.currentTime().seconds
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed.isFinite ? elapsed : 0
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.rate > 0 ? 1.0 : 0.0
    }

    private func updatePlaybackPosition() {
        guard let player = backgroundPlayer, var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        refreshPlaybackPosition(in: &info, of: player)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func installRemoteCommands() {
        removeRemoteCommands()
        let center = MPRemoteCommandCenter.shared()
        let skip = Self.backgroundSkipInterval
        center.playCommand.addTarget(handler: Self.command(self) { $0.backgroundSetPaused(false) })
        center.pauseCommand.addTarget(handler: Self.command(self) { $0.backgroundSetPaused(true) })
        center.togglePlayPauseCommand.addTarget(handler: Self.command(self) { controller in
            controller.backgroundSetPaused((controller.backgroundPlayer?.rate ?? 0) > 0)
        })
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skip)]
        center.skipForwardCommand.addTarget(handler: Self.command(self) { $0.backgroundSkip(by: skip) })
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skip)]
        center.skipBackwardCommand.addTarget(handler: Self.command(self) { $0.backgroundSkip(by: -skip) })
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                        center.skipForwardCommand, center.skipBackwardCommand] {
            command.isEnabled = true
        }
    }

    private func removeRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                        center.skipForwardCommand, center.skipBackwardCommand] {
            command.removeTarget(nil)
            command.isEnabled = false
        }
    }

    // MARK: - Handlers the system calls on its own queues

    /// ⚠️ **BUILT OUTSIDE THE MAIN ACTOR, ON PURPOSE.** A closure written in a
    /// `@MainActor` method is itself main-actor isolated, and Swift 6 traps
    /// when it runs anywhere else. MediaPlayer calls the artwork's handler on
    /// its own queue (it crashed the app the moment a cover was published,
    /// `_dispatch_assert_queue_fail` under `-[MPMediaItemArtwork
    /// jpegDataWithSize:]`), and makes no promise about the remote commands'.
    private nonisolated static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    /// A remote command's handler: answers at once, and does the work on the
    /// main actor.
    private nonisolated static func command(
        _ controller: VideoPlaybackController,
        _ body: @escaping @MainActor @Sendable (VideoPlaybackController) -> Void
    ) -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { [weak controller] _ in
            Task { @MainActor in
                guard let controller else { return }
                body(controller)
            }
            return .success
        }
    }

    /// Through `setPaused`, not the player, so the pause anchor and the
    /// surface's queued frames stay right for when the feed takes over again.
    func backgroundSetPaused(_ paused: Bool) {
        guard let surface = backgroundSurface else { return }
        setPaused(paused, in: surface)
        updatePlaybackPosition()
    }

    func backgroundSkip(by seconds: Double) {
        guard let surface = backgroundSurface, let player = backgroundPlayer,
              let item = player.currentItem else { return }
        let duration = item.duration.seconds
        var target = player.currentTime().seconds + seconds
        if duration.isFinite, duration > 0 { target = min(max(target, 0), max(duration - 0.1, 0)) }
        seek(toSeconds: max(target, 0), in: surface, toleranceSeconds: 0)
        // The seek settles a moment later; the Lock Screen is told where it
        // asked to be, which is where it will be.
        if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(target, 0)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }
}
