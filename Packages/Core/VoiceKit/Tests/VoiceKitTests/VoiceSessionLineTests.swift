import Foundation
import Testing
@testable import VoiceKit

/// The audio session's calls off the main thread (measured on the owner's
/// iPhone, 2026-11-06: a release held it 0.6 s).
struct VoiceSessionLineTests {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func add(_ entry: String) { lock.withLock { entries.append(entry) } }
        var all: [String] { lock.withLock { entries } }
    }

    /// A release runs on the line, not on the caller's thread.
    @Test func aReleaseNeverHoldsTheCaller() async {
        let line = VoiceSessionLine()
        let log = Log()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            line.release {
                log.add(Thread.isMainThread ? "main" : "line")
                done.resume()
            }
        }
        #expect(log.all == ["line"])
    }

    /// A claim cancels a release that has not begun: a play right after a
    /// pause keeps the session. Deterministic: the line is held by a first
    /// release while a second waits behind it, and the claim's cancelling
    /// step runs before the line is let go — no timing (CI run 42277429531
    /// raced a sleep).
    @Test func aClaimCancelsAReleaseNotBegun() {
        let line = VoiceSessionLine()
        let log = Log()
        let gate = DispatchSemaphore(value: 0)
        let holding = DispatchSemaphore(value: 0)
        line.release {                        // holds the line
            holding.signal()
            gate.wait()
        }
        holding.wait()
        line.release { log.add("release") }   // queued behind it, not begun
        line.cancelPendingReleases()          // what a claim does first
        gate.signal()
        line.claim { log.add("claim") }
        #expect(log.all == ["claim"], "the queued release was cancelled")
    }

    /// A claim waits for a release under way: never activated, then
    /// deactivated.
    @Test func aClaimWaitsForAReleaseUnderWay() {
        let line = VoiceSessionLine()
        let log = Log()
        let started = DispatchSemaphore(value: 0)
        line.release {
            started.signal()
            Thread.sleep(forTimeInterval: 0.05)
            log.add("release")
        }
        started.wait()
        line.claim { log.add("claim") }
        #expect(log.all == ["release", "claim"])
    }
}
