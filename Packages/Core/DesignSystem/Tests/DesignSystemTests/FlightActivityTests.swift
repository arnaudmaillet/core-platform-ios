import DesignSystem
import Foundation
import Testing
import UIKit

/// A flight's self-release (#2590): a flight nobody lands releases itself
/// after its hold — the safety net for a transition UIKit abandons — and a
/// test's flight, begun with no hold, lasts until the test lands it. The
/// holds here are short and injected: no test waits ten real seconds.
@MainActor
struct FlightActivityTests {
    private static let shortHold: TimeInterval = 0.05

    /// A view in a shown window: a flight is asked about through a view,
    /// whose window it reads.
    private func hostedView() -> (UIView, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.isHidden = false
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        window.addSubview(view)
        return (view, window)
    }

    /// Waits on the state with a budget of looks, never a deadline: a
    /// starved runner costs no budget.
    private func settle(until condition: () -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func theFlightsKeepATenSecondSafetyNet() {
        #expect(FlightActivity.maximumHold == 10)
    }

    @Test func aFlightNobodyLandsReleasesItselfAfterItsHold() async {
        let (view, window) = hostedView()
        defer { window.isHidden = true }
        let flight = FlightActivity.begin(in: window, maximumHold: Self.shortHold)
        defer { flight.release() }
        #expect(FlightActivity.isActive(for: view))

        let released = await settle { !FlightActivity.isActive(for: view) }
        #expect(released, "a flight nobody landed held on: every emote stays still for the session")
    }

    @Test func aFlightWithNoHoldLastsUntilItsOwnerLandsIt() async throws {
        let (view, window) = hostedView()
        defer { window.isHidden = true }
        // A flight landed at once, whose self-release fires later: it must
        // not end the next one.
        FlightActivity.begin(in: window, maximumHold: Self.shortHold).release()
        let flight = FlightActivity.begin(in: window, maximumHold: .infinity)
        defer { flight.release() }

        // A flight elsewhere, begun later with the same hold: once it has
        // released itself, every earlier self-release has run.
        let (probe, probeWindow) = hostedView()
        defer { probeWindow.isHidden = true }
        let neighbour = FlightActivity.begin(in: probeWindow, maximumHold: Self.shortHold)
        defer { neighbour.release() }
        let timedOut = await settle { !FlightActivity.isActive(for: probe) }
        try #require(timedOut, "the neighbour's flight never released itself")

        #expect(FlightActivity.isActive(for: view), "a flight with no hold ended by itself")
        flight.release()
        #expect(!FlightActivity.isActive(for: view), "the flight did not end when its owner landed it")
    }
}
