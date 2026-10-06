/// Waits on STATE, not time: polls until `condition` holds and returns at once
/// when it does, giving up after `looks` looks (2,000 is about 10 s on a free
/// main actor).
///
/// ⚠️ LOOKS, NOT A WALL-CLOCK DEADLINE. On CI runners the main thread is held
/// by neighbouring suites for seconds at a time, and the whole test process
/// has frozen for two minutes (Profile, run 37318287644). A 3 s deadline
/// expired while the thing it waited for — `EmoteScrollPlayback`'s 4 Hz settle
/// watch, which runs on that same main actor — could not run either, and the
/// one look left came before the watch's turn: `aStoppedGlideComesToRest…`
/// read `isScrolling → true` on #493 (run 37213961982) and #550 (run
/// 37420680414). A frozen process now costs no budget, and the watch gets
/// every turn the wait gives up.
///
/// The waits that matter are `#require`d: one that gives up silently makes
/// the next step a no-op.
@MainActor
@discardableResult
func settle(looks: Int = 2_000, until condition: () -> Bool) async -> Bool {
    for _ in 0..<looks {
        await Task.yield()
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
