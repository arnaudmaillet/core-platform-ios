import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import UIKit

/// Which way the camera faces.
enum CapturePosition: Equatable, Sendable {
    case back
    case front

    var flipped: CapturePosition { self == .back ? .front : .back }
}

/// What the author has let the camera use.
enum CaptureAuthorization: Equatable, Sendable {
    /// The camera may be used. `microphone` says whether clips carry sound.
    case authorized(microphone: Bool)
    /// Refused, or refusable only from Settings.
    case denied
}

/// One of the zoom stops a camera offers — "0.5", "1", "2", "3" — in the
/// DISPLAY scale the author reads, where 1 is the main wide lens.
struct CaptureLens: Equatable, Sendable {
    /// The display factor: 0.5 for the ultra-wide, 1 for the wide.
    let factor: CGFloat

    /// How the chip spells it: "0.5", "1", "2".
    var label: String {
        factor == factor.rounded() ? "\(Int(factor))" : String(format: "%.1f", factor)
    }
}

/// A photograph the camera wrote, and the size it is when drawn upright.
struct CapturedPhoto: Equatable, Sendable {
    let url: URL
    let uprightSize: CGSize
}

enum CaptureSourceError: Error, Equatable {
    case unavailable
    case photoFailed
    case recordingFailed
}

/// A camera frame handed from the source's queue to whoever draws it.
///
/// ⚠️ **`@unchecked Sendable`, AND THE UNCHECKED PART IS A PROMISE THE
/// PRODUCERS KEEP.** `CVPixelBuffer` is not `Sendable`; a buffer handed on is
/// never written again by the source — AVFoundation recycles a pool buffer only
/// once every reference is released, and the simulated source draws each frame
/// into a fresh buffer from its pool. So a reader on another queue reads pixels
/// nobody is changing.
struct CaptureFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    /// When it was captured, on the host clock.
    let time: CMTime
    /// Whether it should be drawn as its own reflection — the front camera's
    /// preview is a mirror, which is what a person expects to see of themself.
    let isMirrored: Bool
}

/// Carries frames from a source's queue to the live preview's renderer.
///
/// ⚠️ **A LOCK, NOT AN ACTOR HOP PER FRAME.** Frames arrive at 30 or 60 a
/// second on a capture queue; hopping each one to an actor would put a task
/// allocation and a scheduler round trip in the path of every frame. The
/// consumer is swapped on the main actor rarely, read under a `Mutex` often.
///
/// ⚠️ **`wantsFrames` IS WHAT LETS A SOURCE STOP PRODUCING THEM.** With no
/// filter chosen and no filter row open, the real camera draws its preview
/// through `AVCaptureVideoPreviewLayer`, which costs this process nothing; the
/// source reads this flag to switch its video data output off, rather than
/// delivering frames that are then thrown away.
final class CaptureFrameFeed: Sendable {
    private let consumer = Mutex<(@Sendable (CaptureFrame) -> Void)?>(nil)
    private let latest = Mutex<CaptureFrame?>(nil)
    private let wanted = Mutex(false)

    init() {}

    /// Called by the source, on its queue.
    func deliver(_ frame: CaptureFrame) {
        latest.withLock { $0 = frame }
        let current = consumer.withLock { $0 }
        current?(frame)
    }

    func setConsumer(_ body: (@Sendable (CaptureFrame) -> Void)?) {
        consumer.withLock { $0 = body }
    }

    var wantsFrames: Bool {
        get { wanted.withLock { $0 } }
        set { wanted.withLock { $0 = newValue } }
    }

    /// The most recent frame, for a snapshot — the filter row's cards.
    var latestFrame: CaptureFrame? { latest.withLock { $0 } }

    func forgetLatest() { latest.withLock { $0 = nil } }
}

/// The clip a recording will become, resolved once, whenever it finishes.
///
/// ⚠️ **EITHER SIDE MAY ARRIVE FIRST.** A recording stopped at once can finish
/// before anyone awaits it; the result is kept until it is asked for.
final class CaptureClipPromise: Sendable {
    private struct State {
        var result: Result<CaptureClip, any Error>?
        var waiter: CheckedContinuation<CaptureClip, any Error>?
    }

    private let state = Mutex(State())

    init() {}

    func fulfil(_ result: Result<CaptureClip, any Error>) {
        let waiter = state.withLock { state -> CheckedContinuation<CaptureClip, any Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(with: result)
    }

    var value: CaptureClip {
        get async throws {
            try await withCheckedThrowingContinuation { continuation in
                let ready = state.withLock { state -> Result<CaptureClip, any Error>? in
                    if let result = state.result { return result }
                    state.waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        }
    }
}

/// A camera, behind a seam.
///
/// ⚠️ **TWO IMPLEMENTATIONS, AND THE SECOND ONE IS NOT A TEST DOUBLE.**
/// `AVCaptureSource` drives the device's cameras; `SimulatedCaptureSource`
/// stands in wherever there are none — which is every simulator, where
/// AVFoundation exposes ZERO capture devices (measured, and recorded in the
/// deleted `CameraViewController`'s note: `devices=0`, the session running with
/// no inputs). Without it, none of the capture flow could be seen before a
/// phone: it draws a moving picture, writes a real photograph and real clips,
/// and answers zoom, lenses, flash and flip visibly. `makeCaptureSource()`
/// picks between them by asking whether a device exists, not whether this is a
/// simulator build.
///
/// Every call is on the main actor; each implementation does its blocking work
/// on a queue of its own.
@MainActor
protocol CaptureSource: AnyObject {
    /// Asks for camera and microphone access if never asked, and reports it.
    func authorize() async -> CaptureAuthorization

    /// Configures (once) and runs the session. Idempotent.
    func start()
    /// Stops the session — the screen is not on show.
    func stop()

    /// Where the frames for the FILTERED preview arrive.
    var feed: CaptureFrameFeed { get }

    /// The cheapest unfiltered preview this source can offer, or nil when every
    /// frame goes through `feed`. The screen lays it under the filtered view and
    /// shows whichever the chosen look needs.
    var plainPreview: UIView? { get }

    /// Called on the main actor when the lenses, the zoom range or the position
    /// change — a real session reports its device only once it is running.
    var onStateChange: (() -> Void)? { get set }

    var position: CapturePosition { get }
    /// Turns to the other camera. Resolves once the new one is running.
    func flip() async

    /// The stops the lens chips offer, ascending.
    var lenses: [CaptureLens] { get }
    /// The zoom the author can reach, in display factors.
    var zoomRange: ClosedRange<CGFloat> { get }
    /// The current zoom, in display factors.
    var zoom: CGFloat { get }
    /// Zooms to `factor` (clamped). `smoothly` ramps, for a chip's jump; a pinch
    /// follows the fingers directly.
    func setZoom(_ factor: CGFloat, smoothly: Bool)

    /// Focuses and meters on `point`, in the plain preview's coordinates
    /// normalised to 0...1. A source without focus ignores it.
    func focus(at point: CGPoint)

    /// Whether the current camera has a flash to fire / a torch to light.
    var hasFlash: Bool { get }

    /// Takes a photograph into `folder`.
    func capturePhoto(flash: CaptureFlashMode, into folder: CaptureFolder) async throws -> CapturedPhoto

    /// Starts recording one clip into `url`, until `stopRecording()` is called
    /// or `limit` seconds have been recorded, whichever comes first. The promise
    /// resolves with the finished clip.
    ///
    /// ⚠️ **THE LIMIT IS THE SOURCE'S TO HONOUR.** The take's remaining budget
    /// is handed down as a hard stop (`maxRecordedDuration` on a device), so
    /// the three-minute cap holds to the frame even if the screen is busy.
    ///
    /// ⚠️ **SYNCHRONOUS TO START, AND THAT IS THE ORDERING GUARANTEE.** The start
    /// is on the source's queue before this returns, so a `stopRecording()`
    /// from a finger lifted a moment later is queued BEHIND it. An `async`
    /// start inside a `Task` could run after the stop — a quick hold would then
    /// begin a recording that nothing ever ends.
    func startRecording(to url: URL, torch: Bool, limit: TimeInterval) -> CaptureClipPromise

    /// Ends the recording `record` started. Harmless when none is running.
    func stopRecording()

    /// How long the running recording has been going, in seconds; 0 when none
    /// is.
    var recordedDuration: TimeInterval { get }

    /// Whether frames should flow through `feed` — a look is chosen, or the
    /// filter row wants live cards. A source with a cheaper unfiltered preview
    /// stops producing them when nobody reads them.
    func setDeliversFrames(_ on: Bool)
}

/// The real camera where one exists, the simulated one everywhere else.
///
/// ⚠️ **ASKED OF THE DEVICE, NOT OF THE BUILD.** `#if targetEnvironment` would
/// be right today and wrong on the first Mac that runs this app with a camera
/// attached, or a device whose cameras are all in use by a restriction. A
/// discovery that finds nothing is the one question that is always right.
@MainActor
func makeCaptureSource() -> any CaptureSource {
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-camera-simulated") {
        return SimulatedCaptureSource()
    }
    #endif
    if AVCaptureSource.hasAnyCamera { return AVCaptureSource() }
    return SimulatedCaptureSource()
}
