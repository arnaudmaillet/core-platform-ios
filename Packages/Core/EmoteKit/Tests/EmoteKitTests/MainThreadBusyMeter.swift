import Foundation
@testable import EmoteKit

/// Measures how long the MAIN run loop is busy, turn by turn.
///
/// A turn is timed from `afterWaiting` (the loop woke) to the LAST
/// `beforeWaiting` observer (ordered after every other one, Core Animation's
/// commit and any idle-turn work included) — the stretch during which the
/// main thread could not have handled a touch. Installed in the COMMON modes,
/// so tracking turns count too.
@MainActor
final class MainThreadBusyMeter {
    struct Report: CustomStringConvertible {
        let wallMS: Double
        let busyMS: Double
        let longestMS: Double
        /// Turns longer than a 60 Hz frame.
        let turnsOver16: Int
        let turns: Int

        var description: String {
            String(format: "wall=%.0fms mainBusy=%.0fms longestTurn=%.1fms turns>16ms=%d/%d",
                   wallMS, busyMS, longestMS, turnsOver16, turns)
        }
    }

    private var woke: ContinuousClock.Instant?
    private var turns: [Double] = []
    private var started = ContinuousClock.now
    private var observers: [CFRunLoopObserver] = []

    func start() {
        turns = []
        started = .now
        woke = .now
        let wake = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.woke = .now }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, let woke = self.woke else { return }
                self.turns.append((ContinuousClock.now - woke).milliseconds)
                self.woke = nil
            }
        }
        for observer in [wake, sleep] {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
        observers = [wake, sleep].compactMap { $0 }
    }

    func stop() -> Report {
        observers.forEach { CFRunLoopRemoveObserver(CFRunLoopGetMain(), $0, .commonModes) }
        observers = []
        return Report(
            wallMS: (ContinuousClock.now - started).milliseconds,
            busyMS: turns.reduce(0, +),
            longestMS: turns.max() ?? 0,
            turnsOver16: turns.filter { $0 > 1000.0 / 60 }.count,
            turns: turns.count
        )
    }
}
