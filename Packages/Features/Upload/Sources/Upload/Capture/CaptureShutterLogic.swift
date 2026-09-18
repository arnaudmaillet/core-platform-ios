import CoreGraphics
import Foundation

/// What the shutter DECIDES, apart from how it is drawn: which gesture means a
/// photograph, a clip held, a clip locked, a stop.
///
/// Pure, for `BandPop`'s reason — an animated control is tested by what it
/// decided, never by its drawing (a model value is an END value).
///
/// ```
///          tap (empty take) ───────────────▶ photo
///          tap (take has clips) ───────────▶ record, locked
///   idle ─ hold ─▶ recording ─ release ─────▶ stop
///                     │
///                     └─ slide onto the lock ▶ locked ─ tap ─▶ stop
/// ```
///
/// ⚠️ **ONCE A TAKE HAS A CLIP, A TAP RECORDS.** A tap is a photograph only
/// while the take is empty: a photograph taken halfway through a video would
/// either be dropped or have to leave the take behind, and both lose work.
/// Instagram and TikTok both stop offering the photo once a video is under
/// way; here the same tap starts the next clip hands-free instead.
///
/// ⚠️ **THE LOCK IS TO THE LEFT, AND A VERTICAL SLIDE ZOOMS.** The two ways a
/// finger can leave a held shutter mean different things, which is the
/// convention of every capture surface the author named: sideways onto the
/// padlock locks, upwards zooms in.
struct CaptureShutterLogic: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        /// A finger is holding the shutter and a clip is being recorded.
        case holding
        /// Recording hands-free; a tap stops it.
        case locked
    }

    enum Action: Equatable, Sendable {
        case none
        case takePhoto
        case startRecording(locked: Bool)
        case lock
        case stopRecording
    }

    /// How far left, in points, the finger must travel to reach the padlock.
    static let lockDistance: CGFloat = 72

    /// Points of upward travel per doubling of the zoom.
    static let zoomTravel: CGFloat = 160

    private(set) var phase: Phase = .idle

    /// A tap on the shutter.
    mutating func tap(takeIsEmpty: Bool, takeIsFull: Bool) -> Action {
        switch phase {
        case .idle:
            if takeIsEmpty { return .takePhoto }
            guard !takeIsFull else { return .none }
            phase = .locked
            return .startRecording(locked: true)
        case .holding, .locked:
            phase = .idle
            return .stopRecording
        }
    }

    /// A hold has been recognised.
    mutating func beginHold(takeIsFull: Bool) -> Action {
        guard phase == .idle, !takeIsFull else { return .none }
        phase = .holding
        return .startRecording(locked: false)
    }

    /// The held finger moved by `translation` from where it went down.
    ///
    /// ⚠️ **LOCKED ONCE, AND THEN THE FINGER IS FREE.** After the lock the same
    /// finger may wander anywhere — including back over the shutter — and lift
    /// without stopping anything; only a new tap stops a locked clip.
    mutating func moveHold(by translation: CGPoint) -> Action {
        guard phase == .holding else { return .none }
        guard -translation.x >= Self.lockDistance, abs(translation.y) < Self.lockDistance else { return .none }
        phase = .locked
        return .lock
    }

    /// The held finger lifted (or the gesture was cancelled).
    mutating func endHold() -> Action {
        guard phase == .holding else { return .none }
        phase = .idle
        return .stopRecording
    }

    /// The recording ended on its own — the take's budget ran out, or the
    /// source failed. The shutter goes back to rest without asking.
    mutating func recordingEnded() { phase = .idle }

    /// How far along the lock a held finger is, 0...1 — the padlock's pull.
    static func lockProgress(for translation: CGPoint) -> CGFloat {
        min(1, max(0, -translation.x / lockDistance))
    }

    /// The zoom a held finger asks for: `base` scaled by one doubling per
    /// `zoomTravel` points of UPWARD travel, and never below `base`.
    static func zoom(from base: CGFloat, translation: CGPoint) -> CGFloat {
        let up = max(0, -translation.y)
        return base * pow(2, up / zoomTravel)
    }
}
