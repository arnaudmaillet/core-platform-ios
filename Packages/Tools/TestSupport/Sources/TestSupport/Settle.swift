import Foundation

/// The default budget: 3,000 looks of 10 ms, at least 30 s.
public let defaultSettleLooks = 3_000

/// Waits until `condition` holds, and says whether it did.
///
/// ⚠️ A BUDGET OF LOOKS, NEVER A CLOCK. A look is spent only when the loop
/// runs: on a starved CI runner the main actor can be held for minutes, and a
/// wall-clock deadline would expire during the starvation while a look budget
/// stretches with it (#2392). Each look yields first, so work queued on the
/// caller's actor lands, then checks, then sleeps 10 ms.
///
/// Runs on the caller's actor (`isolation`), so `condition` may read
/// main-actor state. Assert the result, so a timeout says so:
///
///     #expect(await settle { catalog.snapshot.phase == .loaded })
@discardableResult
public func settle(
    looks: Int = defaultSettleLooks,
    isolation: isolated (any Actor)? = #isolation,
    until condition: () async -> Bool
) async -> Bool {
    for _ in 0..<looks {
        await Task.yield()
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
