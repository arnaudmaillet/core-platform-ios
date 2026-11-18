import CoreGraphics
import Foundation

/// The hold on the composer's waveform (#2102), as numbers: what a finger's
/// travel means — the thresholds the big messengers converged on (Signal-iOS,
/// Telegram, WhatsApp; the epic #2105 lists them). Pure, so the gesture is
/// tested without a finger.
struct VoiceHoldGesture: Equatable {
    /// The recording UI shows this long after touch-down — a quick tap never
    /// flashes it (Signal). The microphone starts at once.
    static let revealDelay: TimeInterval = 0.2
    /// Horizontal travel toward the leading edge that cancels.
    static let cancelTravel: CGFloat = 100
    /// Released past this share of `cancelTravel`, the take is cancelled
    /// too (Telegram).
    static let cancelOnRelease: CGFloat = 0.55
    /// Upward travel before the lock starts to fill: no wobble (Signal).
    static let lockDeadZone: CGFloat = 20
    /// Upward travel past the dead zone that locks.
    static let lockTravel: CGFloat = 80
    /// Past this share of the way to cancel, no lock (Telegram).
    static let lockRefusedPastCancel: CGFloat = 0.3

    enum Outcome: Equatable {
        /// Still holding: how far toward cancel (0…1) and toward the lock (0…1).
        case holding(cancel: CGFloat, lock: CGFloat)
        case cancelled
        case locked
    }

    /// Where the finger is from where it touched down, in points: `x`
    /// positive toward the leading edge (the caller mirrors right-to-left),
    /// `y` positive upward.
    static func outcome(leading x: CGFloat, up y: CGFloat) -> Outcome {
        let cancel = min(1, max(0, x / cancelTravel))
        if cancel >= 1 { return .cancelled }
        let lock = min(1, max(0, (y - lockDeadZone) / lockTravel))
        if cancel > lockRefusedPastCancel { return .holding(cancel: cancel, lock: 0) }
        if lock >= 1 { return .locked }
        return .holding(cancel: cancel, lock: lock)
    }

    enum Release: Equatable {
        /// Lifted before the UI showed: a tap — the hint, nothing recorded.
        case tap
        case send
        case cancel
    }

    /// The finger lifted, `heldFor` after touch-down, `x` toward cancel.
    static func release(heldFor: TimeInterval, leading x: CGFloat) -> Release {
        if heldFor < revealDelay { return .tap }
        return x / cancelTravel >= cancelOnRelease ? .cancel : .send
    }
}
