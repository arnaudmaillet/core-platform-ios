import AVFoundation
import QuartzCore

/// `-zoom-live-log`'s view of the PRODUCER: who owns each player, when one is
/// retired, and what its renderer pulls and hands to each surface.
///
/// ⚠️ It exists because the flight side of that log could only ever report
/// the symptom — a card or a page at `frames=0` — and every cause of that
/// symptom lives here: a player retired under a surface that merely joined
/// it, an output with nothing new, a renderer off the clock. Reading the two
/// halves in one stream is what named the early-grab stall.
@MainActor
enum VideoProducerLog {
    #if DEBUG
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-zoom-live-log")
    #else
    static let isEnabled = false
    #endif

    static func emit(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        print(String(format: "[zoom-live] %.3f producer %@", CACurrentMediaTime(), message()))
    }

    /// A short, stable name for a player — enough to tell two apart in one run.
    static func name(_ player: AVPlayer?) -> String {
        guard let player else { return "P-nil" }
        return "P" + String(UInt(bitPattern: ObjectIdentifier(player).hashValue) % 0x1000, radix: 16)
    }
}

extension VideoRenderView {
    /// `label#tag` — a name for a surface in the producer log.
    var debugProducerName: String {
        #if DEBUG
        return "\(debugLabel ?? "unnamed")#\(debugInstanceTag)"
        #else
        return "surface"
        #endif
    }
}
