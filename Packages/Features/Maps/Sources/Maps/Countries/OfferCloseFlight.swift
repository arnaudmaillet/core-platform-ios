import QuartzCore

/// When a country's offer counts as CLOSING — the moment the map lowers the
/// country and flies back to where it was — across the ways its sheet leaves.
///
/// The flight used to wait for the sheet to be GONE (`viewDidDisappear`): the
/// whole dismissal animation, ~0.3-0.5 s, stood between the user's "no thanks"
/// and the first frame of the camera move. It now starts the moment the sheet
/// is committed to leaving, and runs alongside it going down:
///
/// - A dismissal UIKit drives (a tap on the map, an unlock): at its begin.
/// - A drag on the sheet: when the finger lets go of a dismissal that
///   continues. NOT when the drag starts — UIKit begins an interactive
///   dismissal at the first tug below the detent, and most tugs snap back;
///   flying out on every one of them and back again would be worse than the
///   delay this removes. A release IS the user's gesture ending, so nothing
///   waits on the sheet.
///
/// Each answer is `.close` at most once per offer (no double flight), and a
/// dismissal that is cancelled after the close went out answers `.restore`:
/// the sheet is back up, so the country lifts and is framed above it again.
struct OfferCloseFlight: Equatable {
    enum Action: Equatable {
        case none
        /// The offer is closing: lower the country, fly back.
        case close
        /// A close went out and the sheet came back: undo it.
        case restore
    }

    private enum Phase: Equatable {
        /// Up, nothing in flight.
        case open
        /// Under the finger: may still go back up.
        case dragging
        /// Committed to leaving; the close went out.
        case leaving
    }

    private var phase: Phase = .open

    /// The sheet started to leave. `interactive`: under the user's finger.
    mutating func dismissalBegan(interactive: Bool) -> Action {
        guard phase == .open else { return .none }
        if interactive {
            phase = .dragging
            return .none
        }
        phase = .leaving
        return .close
    }

    /// The finger let go of an interactive dismissal.
    mutating func interactionEnded(cancelled: Bool) -> Action {
        guard phase == .dragging else { return .none }
        if cancelled {
            phase = .open
            return .none
        }
        phase = .leaving
        return .close
    }

    /// The dismissal's transition finished: `cancelled`, the sheet is back up.
    mutating func dismissalEnded(cancelled: Bool) -> Action {
        let was = phase
        phase = cancelled ? .open : .leaving
        switch (was, cancelled) {
        case (.leaving, true): return .restore
        // The release was never reported: close late rather than never.
        case (.dragging, false): return .close
        default: return .none
        }
    }
}

#if DEBUG
/// `-maps-offer-log`: the offer's close, timestamped — the request (a tap on
/// the map, a finger letting go of the sheet), the flight back, and MapKit's
/// first region change. The gap between the request and the region change is
/// the latency the user sees.
enum OfferLog {
    static let isOn = ProcessInfo.processInfo.arguments.contains("-maps-offer-log")

    static func note(_ event: @autoclosure () -> String) {
        guard isOn else { return }
        print(String(format: "[offer] t=%.1f %@", CACurrentMediaTime() * 1000, event()))
    }
}
#endif
