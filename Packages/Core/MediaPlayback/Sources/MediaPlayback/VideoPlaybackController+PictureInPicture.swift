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
        guard let surface, watchedPlayer(in: surface) != nil, let source = surface.pictureInPictureSource else {
            pictureInPicture = nil
            settleAudioSession()
            return false
        }
        if let current = pictureInPicture, current.surface === surface { return true }
        let session = PictureInPictureSession(source: source, surface: surface, playback: self)
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

/// One readied window: the system's controller and the surface it lifts.
@MainActor
final class PictureInPictureSession: NSObject, AVPictureInPictureControllerDelegate {
    let controller: AVPictureInPictureController
    weak var surface: VideoRenderView?
    private weak var playback: VideoPlaybackController?

    init(source: AVPictureInPictureController.ContentSource, surface: VideoRenderView, playback: VideoPlaybackController) {
        controller = AVPictureInPictureController(contentSource: source)
        self.surface = surface
        self.playback = playback
        super.init()
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in self?.playback?.pictureInPictureDidChange(active: true) }
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
