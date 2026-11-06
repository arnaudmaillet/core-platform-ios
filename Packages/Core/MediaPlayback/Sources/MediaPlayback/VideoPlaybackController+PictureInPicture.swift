import AVFoundation
import AVKit
import UIKit

extension VideoRenderView {
    /// The layer Picture in Picture lifts out of the app: the sample-buffer
    /// layer frames are enqueued on, or the legacy player layer.
    var pictureInPictureSource: AVPictureInPictureController.ContentSource? {
        if let layer = layer as? AVSampleBufferDisplayLayer {
            return .init(sampleBufferDisplayLayer: layer, playbackDelegate: PictureInPicturePlayback.shared)
        }
        if let layer = layer as? AVPlayerLayer {
            return .init(playerLayer: layer)
        }
        return nil
    }
}

extension VideoPlaybackController {
    /// Whether this device can show Picture in Picture at all.
    public static var supportsPictureInPicture: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    /// Picture in Picture (#483): readies the clip playing in `surface` to be
    /// lifted into a floating window when the app leaves the screen; nil
    /// lets go of the one readied. Returns whether a window can start.
    ///
    /// ⚠️ **THE SESSION IS `.playback` FOR AS LONG AS A CLIP IS READIED.** The
    /// system starts the window as the app resigns, from the session it finds
    /// — an `.ambient` one is refused. So with Picture in Picture turned on,
    /// the feed's sound plays through the ring switch; the setting says so.
    ///
    /// ⚠️ **AN ACTIVE WINDOW IS NEVER RE-POINTED.** Readying another surface
    /// while the window is up would pull the picture out from under it; the
    /// request is ignored until the window has closed.
    @discardableResult
    public func armPictureInPicture(for surface: VideoRenderView?) -> Bool {
        guard Self.supportsPictureInPicture else { return false }
        if let active = pictureInPicture, active.controller.isPictureInPictureActive {
            return active.surface === surface
        }
        guard let surface, let player = watchedPlayer(in: surface), let controller = surface.readiedPictureInPicture() else {
            pictureInPicture?.disarm()
            pictureInPicture = nil
            settleAudioSession()
            return false
        }
        if let current = pictureInPicture, current.surface === surface, current.player === player { return true }
        pictureInPicture?.disarm()
        let session = PictureInPictureSession(controller: controller, surface: surface, player: player, playback: self)
        pictureInPicture = session
        PictureInPicturePlayback.shared.controller = self
        refreshPictureInPictureState()
        settleAudioSession()
        return true
    }

    /// Whether the floating window is up.
    public var isPictureInPictureActive: Bool {
        pictureInPicture?.controller.isPictureInPictureActive ?? false
    }

    /// Whether a clip is readied for the window.
    public var isPictureInPictureArmed: Bool { pictureInPicture != nil }

    /// Closes the floating window, if one is up (back on screen).
    public func stopPictureInPicture() {
        guard let session = pictureInPicture, session.controller.isPictureInPictureActive else { return }
        session.controller.stopPictureInPicture()
    }

    /// Whether the window that just closed handed the clip back to the app
    /// (its "back to the app" button) rather than closing on its own.
    public var pictureInPictureClosedIntoApp: Bool { pictureInPicture?.closedIntoApp ?? false }

    /// Called whenever the window opens or closes. `true` when it opened.
    public var onPictureInPictureChange: ((Bool) -> Void)? {
        get { pictureInPictureObserver }
        set { pictureInPictureObserver = newValue }
    }

    // MARK: - Window state

    /// Tells the window how the readied clip is doing: paused or not, and
    /// how long it is. Read by the system on its own queue.
    func refreshPictureInPictureState() {
        guard let session = pictureInPicture, let surface = session.surface,
              let player = watchedPlayer(in: surface) else { return }
        let duration = player.currentItem?.duration ?? .invalid
        PictureInPicturePlayback.shared.update(
            paused: player.timeControlStatus == .paused,
            range: duration.isNumeric && duration.seconds > 0
                ? CMTimeRange(start: .zero, duration: duration)
                : CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        )
        session.controller.invalidatePlaybackState()
    }

    func pictureInPictureDidChange(active: Bool) {
        // While the window is up the app is off screen, where the display link
        // that paces every renderer does not fire: without another tick the
        // window would hold one frozen picture.
        VideoFrameClock.shared.pacesWithoutDisplay = active
        refreshPictureInPictureState()
        pictureInPictureObserver?(active)
    }

    func pictureInPictureSetPlaying(_ playing: Bool) {
        guard let surface = pictureInPicture?.surface else { return }
        setPaused(!playing, in: surface)
        refreshPictureInPictureState()
    }

    func pictureInPictureSkip(by seconds: Double) {
        guard let surface = pictureInPicture?.surface, let player = watchedPlayer(in: surface),
              let item = player.currentItem else { return }
        let duration = item.duration.seconds
        var target = player.currentTime().seconds + seconds
        if duration.isFinite, duration > 0 { target = min(max(target, 0), max(duration - 0.1, 0)) }
        seek(toSeconds: max(target, 0), in: surface, toleranceSeconds: 0)
    }
}

extension VideoRenderView {
    /// This surface's controller, made once (`pictureInPictureController`);
    /// nil when its layer cannot float.
    func readiedPictureInPicture() -> AVPictureInPictureController? {
        if let controller = pictureInPictureController { return controller }
        guard let source = pictureInPictureSource else { return nil }
        let controller = AVPictureInPictureController(contentSource: source)
        pictureInPictureController = controller
        return controller
    }
}

/// One readied window: the surface's controller, while it may start on its
/// own, and the player it shows.
@MainActor
final class PictureInPictureSession: NSObject, AVPictureInPictureControllerDelegate {
    let controller: AVPictureInPictureController
    weak var surface: VideoRenderView?
    weak var player: AVPlayer?
    private weak var playback: VideoPlaybackController?
    /// ⚠️ THE WINDOW STARTS ONLY FOR A CLIP IT SEES PLAYING. Its "paused?" is
    /// answered from a cache (`PictureInPicturePlayback`), filled when the
    /// clip was readied — often before its player had started, so the cache
    /// said "paused" for good and the system never opened the window (the
    /// owner's device, 2026-11-06). The player's every start and stop is
    /// passed on now.
    private var statusObservation: NSKeyValueObservation?

    init(controller: AVPictureInPictureController, surface: VideoRenderView, player: AVPlayer, playback: VideoPlaybackController) {
        self.controller = controller
        self.surface = surface
        self.player = player
        self.playback = playback
        super.init()
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        statusObservation = player.observe(\.timeControlStatus) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, let owner = self.playback, owner.pictureInPicture === self else { return }
                owner.refreshPictureInPictureState()
            }
        }
    }

    /// Another clip is readied, or none: this surface's controller stays
    /// with it (`VideoRenderView.pictureInPictureController`), and no longer
    /// starts on its own.
    func disarm() {
        statusObservation = nil
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        if controller.delegate === self { controller.delegate = nil }
    }

    /// The window is closing back into the app (`restoreUserInterface…`):
    /// the page it came from takes the clip over, playing, as it is.
    private(set) var closedIntoApp = false

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            self?.closedIntoApp = false
            self?.playback?.pictureInPictureDidChange(active: true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in self?.playback?.pictureInPictureDidChange(active: false) }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor [weak self] in self?.playback?.pictureInPictureDidChange(active: false) }
    }

    /// The window's "back to the app" button: the app comes forward with the
    /// clip where it was, so there is nothing to rebuild.
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor [weak self] in self?.closedIntoApp = true }
        completionHandler(true)
    }
}

/// The sample-buffer window's playback questions and commands.
///
/// ⚠️ **NOT ON THE MAIN ACTOR, AND ITS ANSWERS ARE CACHED.** The system asks
/// "paused?" and "how long?" synchronously on its own queue — a main-actor
/// object would trap there (see `continueInBackground`'s artwork). The
/// controller pushes the answers in (`update`), and commands hop to the main
/// actor.
final class PictureInPicturePlayback: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate, @unchecked Sendable {
    static let shared = PictureInPicturePlayback()

    private let lock = NSLock()
    private var paused = false
    private var range = CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    /// Read only on the main actor.
    nonisolated(unsafe) weak var controller: VideoPlaybackController?

    func update(paused: Bool, range: CMTimeRange) {
        lock.withLock {
            self.paused = paused
            self.range = range
        }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        lock.withLock { paused = !playing }
        Task { @MainActor [weak self] in self?.controller?.pictureInPictureSetPlaying(playing) }
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        lock.withLock { range }
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        lock.withLock { paused }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping @Sendable () -> Void
    ) {
        let seconds = skipInterval.seconds
        Task { @MainActor [weak self] in
            self?.controller?.pictureInPictureSkip(by: seconds)
            completionHandler()
        }
    }
}
