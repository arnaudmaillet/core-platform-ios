import CoreVideo
import MediaPlayback
import UIKit
import VideoToolbox

/// Something that can hand the band the frame it is showing.
///
/// A protocol so the driver's lifecycle can be pinned by tests without a
/// decoder; `VideoRenderView` is the only real conformer.
@MainActor
public protocol LiveBackdropFrameSource: AnyObject {
    /// Changes whenever a new frame is displayed. The same token twice means
    /// the same picture, so there is nothing to redo (a paused clip).
    var liveFrameToken: CFTimeInterval { get }
    /// The decoded frame on display, nil when there is none.
    var liveFrameBuffer: CVPixelBuffer? { get }
    /// Whether the source is drawing decoded frames on screen right now, as
    /// opposed to a poster, nothing, or nothing anyone can see.
    var isShowingLiveFrames: Bool { get }
}

extension VideoRenderView: LiveBackdropFrameSource {
    public var liveFrameToken: CFTimeInterval { lastFrameHostTime }
    public var liveFrameBuffer: CVPixelBuffer? { currentFrameBuffer }
    public var isShowingLiveFrames: Bool { window != nil && !isHidden && hasFrame }
}

/// The blurred band of a fitted CLIP, playing: the page's backdrop redrawn
/// from the clip's own decoded frames, a dozen times a second.
///
/// ## Why this design, and not a second surface
///
/// Three were weighed (the numbers are in the PR that introduced this):
///
/// - **A second surface on the same player, under a system blur.** No extra
///   decode — the sample-buffer renderer already feeds N surfaces — but a
///   `UIVisualEffectView` over a moving picture is a full-screen blur pass on
///   EVERY composited frame, and under `-avplayer-render` a second layer
///   steals the one render slot and blacks the picture itself.
/// - **A second player on the same asset.** A second decoder for a picture
///   nobody can see detail in. Last resort, never needed.
/// - **This one: tap the frame the pipeline already has.** The renderer keeps
///   the buffer it last displayed (`VideoRenderView.currentFrameBuffer`), so a
///   sample costs no decode, no seek and no second output: VideoToolbox scales
///   it to `MediaBackdrop.reducedLongSide` pixels (the hardware scaler on a
///   device), and `MediaBackdrop.finish` blurs and darkens that tiny picture
///   exactly as it does a poster's. The page composites one 40-pixel image,
///   as it did for the still.
///
/// ⚠️ THE SAME LOOK, BY CONSTRUCTION: the still and the live band share their
/// whole second half (`MediaBackdrop.finish`), so the hand-over from poster to
/// playing is a change of picture, never a change of treatment.
///
/// ## Rate
///
/// `samplesPerSecond` (12), off the main thread, one sample in flight at most,
/// and none at all while the frame has not changed — a paused clip costs a
/// token comparison per tick. Each new band fades over the sample interval,
/// so a dozen pictures a second read as continuous colour: at this blur, a
/// band cannot show motion finer than that anyway.
///
/// ## Lifecycle
///
/// The host says when the band MAY run (`setActive`: the page on screen, its
/// clip framed `.fitBlurred`). It runs only if the system allows it too —
/// Reduce Motion and Low Power Mode both put the still back — and only while
/// the source is drawing live frames in a window. Everything else keeps the
/// still: neighbours, a paused page (it keeps the frame it paused on), a page
/// being flown by a hero (its surface has left the card), `-avplayer-render`
/// (no retained frame to read).
@MainActor
public final class LiveMediaBackdrop {
    /// How many times a second the band is redrawn while the clip plays.
    public nonisolated static let samplesPerSecond: Double = 12

    /// How long the FIRST live band takes to replace the still — a poster is a
    /// thumbnail, often cropped, so the two differ by more than two frames do.
    static let firstLiveFade: TimeInterval = 0.3

    /// Off for the whole process under `-still-video-backdrop`: the A/B arm
    /// for measuring what the live band costs, in any build.
    public static let isEnabledByProcess: Bool =
        !ProcessInfo.processInfo.arguments.contains("-still-video-backdrop")

    private weak var target: UIImageView?
    /// The surface whose frames the band is made from.
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

    private var link: CADisplayLink?
    private var lastSampleTime: CFTimeInterval = -.infinity
    private var lastToken: CFTimeInterval = .nan
    private var isConverting = false
    /// Bumped by everything that makes an in-flight sample obsolete, so a
    /// frame that lands after its page moved on is dropped, not drawn.
    private var generation = 0
    /// The display link's target and the settings observer, holding this band
    /// weakly — see `Proxy`.
    private lazy var proxy = Proxy(self)

    public init(target: UIImageView) {
        self.target = target
        let center = NotificationCenter.default
        center.addObserver(proxy, selector: #selector(Proxy.settingsChanged),
                           name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        center.addObserver(proxy, selector: #selector(Proxy.settingsChanged),
                           name: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil)
    }

    /// Whether the band is sampling right now.
    public private(set) var isRunning = false

    /// Whether running starts a display link. Off in specs, which tick by
    /// hand on a clock of their own that a real link would interleave with.
    var usesDisplayLink = true

    /// The host's still band. Drawn at once unless the band is live — and
    /// while it is, kept for the moment it stops being.
    public func setStill(_ image: UIImage?) {
        still = image
        guard !isShowingLive else { return }
        target?.image = image
    }

    /// Whether the band may run. Turning it off keeps the live frame on
    /// screen — the picture has paused on that same frame — and only stops
    /// the sampling.
    public func setActive(_ active: Bool) {
        guard isAllowed != active else { return }
        isAllowed = active
        reconcile()
    }

    /// Puts the still back and forgets everything live: a recycled page, a new
    /// post, a framing that is no longer blurred.
    public func returnToStill(animated: Bool = false) {
        generation += 1
        isConverting = false
        lastToken = .nan
        lastSampleTime = -.infinity
        guard isShowingLive else { return }
        isShowingLive = false
        show(still, fade: animated ? Self.firstLiveFade : 0)
    }

    fileprivate func reconcileForSettings() { reconcile() }

    private func reconcile() {
        let suppressed = isSuppressedBySystem()
        let wanted = isAllowed && !suppressed && Self.isEnabledByProcess
        if suppressed, isShowingLive { returnToStill(animated: true) }
        guard wanted != isRunning else { return }
        isRunning = wanted
        if wanted {
            guard usesDisplayLink else { return }
            let link = CADisplayLink(target: proxy, selector: #selector(Proxy.tick(_:)))
            let rate = Float(Self.samplesPerSecond)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: rate / 2, maximum: rate, preferred: rate)
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            link?.invalidate()
            link = nil
            // A sample in flight belongs to a band that has stopped.
            generation += 1
            isConverting = false
        }
    }

    /// Whether a tick should take a sample: a new frame, the interval elapsed,
    /// nothing in flight. Pure, so the rate limit is pinned without a clock.
    nonisolated static func shouldSample(
        now: CFTimeInterval, lastSample: CFTimeInterval,
        token: CFTimeInterval, lastToken: CFTimeInterval, isConverting: Bool
    ) -> Bool {
        guard !isConverting, token != lastToken else { return false }
        // A hair under the interval, so a display link that fires a little
        // early is not held back a whole extra tick.
        return now - lastSample >= (1 / samplesPerSecond) * 0.9
    }

    /// One tick of the band's clock.
    func tick(now: CFTimeInterval) {
        guard isRunning, let target, target.window != nil, !target.isHidden, let source else { return }
        guard source.isShowingLiveFrames else {
            // The surface went back to its poster (a stopped player): so does
            // the band.
            if isShowingLive { returnToStill(animated: true) }
            return
        }
        let token = source.liveFrameToken
        guard Self.shouldSample(now: now, lastSample: lastSampleTime, token: token,
                                lastToken: lastToken, isConverting: isConverting),
              let buffer = source.liveFrameBuffer
        else { return }
        lastSampleTime = now
        lastToken = token
        isConverting = true
        let generation = generation
        let frame = FrameBox(buffer: buffer)
        let reduce = reduce
        let started = CACurrentMediaTime()
        BackdropFrameReducer.queue.async { [weak self] in
            let result = ImageBox(image: reduce(frame.buffer))
            let cost = CACurrentMediaTime() - started
            Task { @MainActor in
                self?.deliver(result.image, generation: generation, cost: cost)
            }
        }
    }

    private func deliver(_ image: UIImage?, generation: Int, cost: CFTimeInterval) {
        guard generation == self.generation else { return }
        isConverting = false
        LiveBackdropTrace.note(cost: cost)
        guard let image, isRunning else { return }
        let fade = isShowingLive ? 1 / Self.samplesPerSecond : Self.firstLiveFade
        isShowingLive = true
        show(image, fade: fade)
        #if DEBUG
        debugDeliveredCount += 1
        #endif
    }

    private func show(_ image: UIImage?, fade: TimeInterval) {
        guard let target else { return }
        if fade > 0, target.window != nil {
            // A cross-dissolve of the layer's contents, composited by the render
            // server: the main thread sets one image and is done.
            let transition = CATransition()
            transition.type = .fade
            transition.duration = fade
            target.layer.add(transition, forKey: "liveBackdrop")
        }
        target.image = image
    }

    #if DEBUG
    /// How many live bands have been drawn, for a spec.
    private(set) var debugDeliveredCount = 0
    /// Ticks the band's clock by hand, for a spec that has no display link.
    func debugTick(now: CFTimeInterval) { tick(now: now) }
    var debugIsConverting: Bool { isConverting }
    /// What a Reduce Motion or Low Power notification does.
    func debugSettingsChanged() { reconcile() }
    #endif
}

/// `CADisplayLink` RETAINS ITS TARGET, so the band is never its target: this
/// proxy is, and it holds the band weakly. A band that goes away with its page
/// is outlived by at most one tick, which finds no owner and invalidates the
/// link. It is also the settings observer — a selector-based observer the
/// notification centre drops by itself when the proxy goes.
@MainActor
private final class Proxy: NSObject {
    weak var owner: LiveMediaBackdrop?
    init(_ owner: LiveMediaBackdrop) { self.owner = owner }

    @objc func tick(_ link: CADisplayLink) {
        guard let owner else {
            link.invalidate()
            return
        }
        owner.tick(now: link.timestamp)
    }

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
        guard let session = session ?? makeSession() else { return nil }
        var destination: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                                  kCVPixelFormatType_32BGRA, attributes, &destination) == kCVReturnSuccess,
              let destination,
              VTPixelTransferSessionTransferImage(session, from: buffer, to: destination) == noErr
        else { return nil }
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(destination, options: nil, imageOut: &image) == noErr else {
            return nil
        }
        return image
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

/// `-live-backdrop-log`: once a second, how many bands were made and what they
/// cost off the main thread. The measurement behind the design, kept.
enum LiveBackdropTrace {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-live-backdrop-log")
    @MainActor private static var window: (start: CFTimeInterval, count: Int, total: Double, worst: Double) = (0, 0, 0, 0)

    @MainActor static func note(cost: CFTimeInterval) {
        guard isEnabled else { return }
        let now = CACurrentMediaTime()
        if window.start == 0 { window.start = now }
        window.count += 1
        window.total += cost
        window.worst = max(window.worst, cost)
        guard now - window.start >= 1 else { return }
        print(String(format: "[live-backdrop] %.3f bands=%d/%.1fs avg=%.2fms worst=%.2fms",
                     now, window.count, now - window.start,
                     window.total / Double(window.count) * 1000, window.worst * 1000))
        window = (now, 0, 0, 0)
    }
}
