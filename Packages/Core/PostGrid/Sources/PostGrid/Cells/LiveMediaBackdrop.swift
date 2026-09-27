import CoreVideo
import MediaPlayback
import UIKit
import VideoToolbox

/// Whether the band may follow a surface's frames right now.
///
/// A protocol so the driver's lifecycle can be pinned by tests without a
/// decoder; `VideoRenderView` and the feed's card conform.
@MainActor
public protocol LiveBackdropFrameSource: AnyObject {
    /// Whether the source is drawing decoded frames on screen right now, as
    /// opposed to a poster, nothing, or nothing anyone can see.
    var isShowingLiveFrames: Bool { get }
}

extension VideoRenderView: LiveBackdropFrameSource {
    public var isShowingLiveFrames: Bool { window != nil && !isHidden && hasFrame }
}

/// The blurred band of a fitted CLIP, playing: the page's backdrop redrawn
/// from the clip's own decoded frames — EVERY frame, and on the same refresh
/// as the picture.
///
/// ## Why frame-exact, and how
///
/// The first version (#271) sampled the frame the renderer had last shown,
/// twelve times a second, made the band off the main thread and cross-faded
/// it in over a twelfth of a second. On screen that is a band that trails its
/// picture — a cut reached the band refreshes after the picture, and smeared
/// in — which reads as the two being out of sync, because they were.
///
/// Now the band is a `VideoFrameCompanion` of the surface it frames. While it
/// asks, the renderer pulls each frame a refresh or two BEFORE it is due and
/// hands it over (`prepare`): the band scales and blurs it off the main thread
/// in that time. The renderer then enqueues the frame at the refresh it was
/// always going to be shown at, and in the same main-thread turn tells the
/// band (`present`), which swaps its picture with no animation. One turn, one
/// commit, one refresh for both changes.
///
/// A band that is not ready at `present` (the reducer fell behind) is shown
/// the moment it is, and counted as late under `-live-backdrop-log` — never
/// held back, and never drawn for a frame the picture has already left.
///
/// ## Why this reduction, and not a second surface
///
/// Three were weighed (#271):
///
/// - **A second surface on the same player, under a system blur.** No extra
///   decode — the sample-buffer renderer already feeds N surfaces — but a
///   `UIVisualEffectView` over a moving picture is a full-screen blur pass on
///   EVERY composited frame, and under `-avplayer-render` a second layer
///   steals the one render slot and blacks the picture itself.
/// - **A second player on the same asset.** A second decoder for a picture
///   nobody can see detail in. Last resort, never needed.
/// - **This one: reduce the frame the pipeline already has.** No decode, no
///   seek and no second output: VideoToolbox scales the frame to
///   `MediaBackdrop.reducedLongSide` pixels (the hardware scaler on a device),
///   and `MediaBackdrop.finish` blurs and darkens that tiny picture exactly as
///   it does a poster's. The page composites one 40-pixel image, as it did for
///   the still.
///
/// ⚠️ THE SAME LOOK, BY CONSTRUCTION: the still and the live band share their
/// whole second half (`MediaBackdrop.finish`), so the hand-over from poster to
/// playing is a change of picture, never a change of treatment.
///
/// ## Cost
///
/// One reduction per decoded frame (25–30 a second), off the main thread, at
/// most `maxInFlight` at once. The main thread sets one image per frame. A
/// paused clip decodes nothing, so it costs nothing. The numbers are in the PR
/// that made the band frame-exact.
///
/// ## Lifecycle
///
/// The host says when the band MAY run (`setActive`: the page on screen, its
/// clip framed `.fitBlurred`) and attaches it to its surface
/// (`VideoRenderView.frameCompanion`). It runs only if the system allows it
/// too — Reduce Motion and Low Power Mode both put the still back — and only
/// while the source is drawing live frames in a window. Everything else keeps
/// the still: neighbours, a paused page (it keeps the frame it paused on), a
/// page being flown by a hero (its surface has left the card), and
/// `-avplayer-render` (no renderer to lead). The still is also what the band
/// shows until the first live frame, which fades in over it.
@MainActor
public final class LiveMediaBackdrop: VideoFrameCompanion {
    /// How long the FIRST live band takes to replace the still — a poster is a
    /// thumbnail, often cropped, so the two differ by more than two frames do.
    static let firstLiveFade: TimeInterval = 0.3

    /// Reductions in flight at once, at most. Two refreshes of lead is one or
    /// two frames; a third would only be a reducer falling behind.
    static let maxInFlight = 3

    /// Off for the whole process under `-still-video-backdrop`: the A/B arm
    /// for measuring what the live band costs, in any build.
    public static let isEnabledByProcess: Bool =
        !ProcessInfo.processInfo.arguments.contains("-still-video-backdrop")

    private weak var target: UIImageView?
    /// Whether the band may follow the surface's frames — see the protocol.
    public weak var source: (any LiveBackdropFrameSource)?

    /// What the band shows when it is not live — the host's blurred poster.
    private(set) var still: UIImage?
    /// Whether the band currently shows a live frame rather than the still.
    public private(set) var isShowingLive = false
    /// The host's permission.
    private var isAllowed = false
    /// Whether the system forbids motion here: Reduce Motion or Low Power.
    /// Injectable so the fallback can be pinned without flipping a setting.
    public var isSuppressedBySystem: () -> Bool = {
        UIAccessibility.isReduceMotionEnabled || ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// The frame reducer, off the main thread. Injectable for tests.
    var reduce: @Sendable (CVPixelBuffer) -> UIImage? = { buffer in
        BackdropFrameReducer.shared.backdrop(from: buffer)
    }

    /// Frames being reduced.
    private var inFlight: Set<VideoFrameID> = []
    /// Bands made for frames not yet on screen.
    private var ready: [VideoFrameID: UIImage] = [:]
    /// A frame on screen whose band is still being made — shown on arrival.
    private var awaiting: VideoFrameID?
    /// The last frame the surface put on screen while the band ran.
    private var lastPresented: VideoFrameID?
    /// Bumped by everything that makes an in-flight reduction obsolete, so a
    /// band that lands after its page moved on is dropped, not drawn.
    private var generation = 0
    /// The settings observer, holding this band weakly — see `Proxy`.
    private lazy var proxy = Proxy(self)

    public init(target: UIImageView) {
        self.target = target
        let center = NotificationCenter.default
        center.addObserver(proxy, selector: #selector(Proxy.settingsChanged),
                           name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        center.addObserver(proxy, selector: #selector(Proxy.settingsChanged),
                           name: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil)
    }

    /// Whether the band follows the clip right now.
    public private(set) var isRunning = false

    /// The host's still band. Drawn at once unless the band is live — and
    /// while it is, kept for the moment it stops being.
    public func setStill(_ image: UIImage?) {
        still = image
        guard !isShowingLive else { return }
        target?.image = image
    }

    /// Whether the band may run. Turning it off keeps the live frame on
    /// screen — the picture has paused on that same frame — and only stops
    /// following.
    public func setActive(_ active: Bool) {
        guard isAllowed != active else { return }
        isAllowed = active
        reconcile()
    }

    /// Puts the still back and forgets everything live: a recycled page, a new
    /// post, a framing that is no longer blurred.
    public func returnToStill(animated: Bool = false) {
        forgetFrames()
        guard isShowingLive else { return }
        isShowingLive = false
        show(still, fade: animated ? Self.firstLiveFade : 0)
    }

    /// The source stopped drawing frames — a stopped player shows its poster —
    /// so a running band shows the still again.
    public func sourceStoppedDrawing() {
        guard isRunning, isShowingLive else { return }
        returnToStill(animated: true)
    }

    fileprivate func reconcileForSettings() { reconcile() }

    private func reconcile() {
        let suppressed = isSuppressedBySystem()
        let wanted = isAllowed && !suppressed && Self.isEnabledByProcess
        if suppressed, isShowingLive { returnToStill(animated: true) }
        guard wanted != isRunning else { return }
        isRunning = wanted
        // A band that stops keeps what it shows and drops what is on its way:
        // those frames belong to a band that has stopped.
        if !wanted { forgetFrames() }
    }

    private func forgetFrames() {
        generation += 1
        inFlight.removeAll()
        ready.removeAll()
        awaiting = nil
        lastPresented = nil
    }

    // MARK: - VideoFrameCompanion

    public var wantsFramesAhead: Bool {
        guard isRunning, let target, target.window != nil, !target.isHidden,
              source?.isShowingLiveFrames == true
        else { return false }
        return true
    }

    public func prepare(_ buffer: CVPixelBuffer, as frame: VideoFrameID) {
        guard wantsFramesAhead, inFlight.count < Self.maxInFlight else { return }
        inFlight.insert(frame)
        let generation = generation
        let box = FrameBox(buffer: buffer)
        let reduce = reduce
        let started = CACurrentMediaTime()
        BackdropFrameReducer.queue.async { [weak self] in
            let result = ImageBox(image: reduce(box.buffer))
            let cost = CACurrentMediaTime() - started
            Task { @MainActor in
                self?.deliver(result.image, for: frame, generation: generation, cost: cost)
            }
        }
    }

    public func present(_ frame: VideoFrameID) {
        guard isRunning else { return }
        lastPresented = frame
        if let image = ready.removeValue(forKey: frame) {
            LiveBackdropTrace.note(onTime: true)
            showLive(image)
        } else if inFlight.contains(frame) {
            awaiting = frame
        } else {
            LiveBackdropTrace.note(onTime: false)
        }
        // Everything made for an earlier frame is past.
        ready = ready.filter { $0.key > frame }
    }

    private func deliver(_ image: UIImage?, for frame: VideoFrameID, generation: Int, cost: CFTimeInterval) {
        guard generation == self.generation else { return }
        inFlight.remove(frame)
        LiveBackdropTrace.note(cost: cost)
        guard let image, isRunning else { return }
        if awaiting == frame {
            // On screen already: late, but the picture is still on this frame.
            awaiting = nil
            LiveBackdropTrace.note(onTime: false)
            showLive(image)
        } else if let lastPresented, frame <= lastPresented {
            // The picture has moved past it: drawn now, it would be a band
            // from the past.
            return
        } else {
            ready[frame] = image
        }
    }

    private func showLive(_ image: UIImage) {
        let first = !isShowingLive
        isShowingLive = true
        show(image, fade: first ? Self.firstLiveFade : 0)
        #if DEBUG
        debugDeliveredCount += 1
        #endif
    }

    private func show(_ image: UIImage?, fade: TimeInterval) {
        guard let target else { return }
        #if DEBUG
        debugLastFade = target.window != nil ? fade : 0
        #endif
        guard fade > 0, target.window != nil else {
            // ⚠️ NO ANIMATION between frames. A cross-fade is a band that is
            // always partly the previous frame — the lag this design removes.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            target.image = image
            CATransaction.commit()
            return
        }
        // A cross-dissolve of the layer's contents, composited by the render
        // server: the main thread sets one image and is done.
        let transition = CATransition()
        transition.type = .fade
        transition.duration = fade
        target.layer.add(transition, forKey: "liveBackdrop")
        target.image = image
    }

    #if DEBUG
    /// How many live bands have been drawn, for a spec.
    private(set) var debugDeliveredCount = 0
    /// How long the last change of picture faded over — 0 for none.
    private(set) var debugLastFade: TimeInterval = -1
    var debugInFlightCount: Int { inFlight.count }
    var debugReadyCount: Int { ready.count }
    /// What a Reduce Motion or Low Power notification does.
    func debugSettingsChanged() { reconcile() }
    #endif
}

/// The settings observer, holding the band weakly — a selector-based observer
/// the notification centre drops by itself when the proxy goes.
@MainActor
private final class Proxy: NSObject {
    weak var owner: LiveMediaBackdrop?
    init(_ owner: LiveMediaBackdrop) { self.owner = owner }

    /// Reduce Motion or Low Power changed. The power notification arrives on
    /// whatever thread changed the setting, hence the hop.
    @objc nonisolated func settingsChanged() {
        Task { @MainActor in self.owner?.reconcileForSettings() }
    }
}

/// A decoded frame crossing to the reducer's queue. The buffer is only read
/// there, and the renderer never writes to a buffer it has handed out.
private struct FrameBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

private struct ImageBox: @unchecked Sendable {
    let image: UIImage?
}

/// Scales a decoded frame down to the backdrop's size and finishes it.
///
/// ⚠️ ONE SESSION, ONE QUEUE. A `VTPixelTransferSession` is not safe to use
/// from two threads, so it is only ever touched on `queue` — and only one page
/// runs a live band at a time, so a single serial queue is never a queue.
final class BackdropFrameReducer: @unchecked Sendable {
    static let shared = BackdropFrameReducer()
    static let queue = DispatchQueue(label: "PostGrid.LiveMediaBackdrop", qos: .userInitiated)

    private var session: VTPixelTransferSession?
    /// Destinations, recycled: a band is made for every frame, and a fresh
    /// IOSurface-backed buffer each time measured a third of the reduction.
    private var pool: (size: CGSize, pool: CVPixelBufferPool)?

    /// The finished band for `buffer`, or nil when it cannot be converted.
    /// Call on `queue` only (tests call it synchronously, which is the same).
    func backdrop(from buffer: CVPixelBuffer) -> UIImage? {
        guard let reduced = reduce(buffer) else { return nil }
        return MediaBackdrop.finish(reduced: reduced)
    }

    /// The frame at `MediaBackdrop.reducedSize`, area-averaged, as an 8-bit
    /// BGRA picture — the same thing the still path's `.high` context draw
    /// produces from a poster.
    func reduce(_ buffer: CVPixelBuffer) -> CGImage? {
        let size = MediaBackdrop.reducedSize(for: CGSize(
            width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)
        ))
        guard let session = session ?? makeSession(),
              let destination = makeDestination(size),
              VTPixelTransferSessionTransferImage(session, from: buffer, to: destination) == noErr
        else { return nil }
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(destination, options: nil, imageOut: &image) == noErr else {
            return nil
        }
        return image
    }

    private func makeDestination(_ size: CGSize) -> CVPixelBuffer? {
        if pool?.size != size {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var created: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
                    == kCVReturnSuccess, let created
            else { return nil }
            pool = (size, created)
        }
        guard let pool = pool?.pool else { return nil }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess
        else { return nil }
        return destination
    }

    private func makeSession() -> VTPixelTransferSession? {
        var created: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault,
                                           pixelTransferSessionOut: &created) == noErr,
              let created
        else { return nil }
        // Averaged, not sampled: a 27× reduction by point sampling would pick a
        // few pixels per band pixel, and the band would shimmer with the grain
        // of whichever pixels those were from one frame to the next.
        VTSessionSetProperty(created, key: kVTPixelTransferPropertyKey_DownsamplingMode,
                             value: kVTDownsamplingMode_Average)
        session = created
        return created
    }
}

/// `-live-backdrop-log`: once a second, how many bands were made, what they
/// cost off the main thread (queue wait included), and how many reached the
/// screen WITH their frame (`onTime`) rather than after it (`late`). The
/// measurement behind the design, kept.
enum LiveBackdropTrace {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-live-backdrop-log")
    @MainActor private static var window = Window()

    private struct Window {
        var start: CFTimeInterval = 0
        var count = 0
        var total: Double = 0
        var worst: Double = 0
        var onTime = 0
        var late = 0
    }

    @MainActor static func note(cost: CFTimeInterval) {
        guard isEnabled else { return }
        window.count += 1
        window.total += cost
        window.worst = max(window.worst, cost)
        flushIfDue()
    }

    @MainActor static func note(onTime: Bool) {
        guard isEnabled else { return }
        if onTime { window.onTime += 1 } else { window.late += 1 }
        flushIfDue()
    }

    @MainActor private static func flushIfDue() {
        let now = CACurrentMediaTime()
        if window.start == 0 { window.start = now }
        guard now - window.start >= 1 else { return }
        print(String(format: "[live-backdrop] %.3f bands=%d/%.1fs avg=%.2fms worst=%.2fms onTime=%d late=%d",
                     now, window.count, now - window.start,
                     window.total / Double(max(window.count, 1)) * 1000, window.worst * 1000,
                     window.onTime, window.late))
        window = Window(start: now)
    }
}
