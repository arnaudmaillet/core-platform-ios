/// Waits on STATE, not time: polls until `condition` holds and returns at once
/// when it does, giving up after `looks` looks (2,000 is about 10 s on a free
/// main actor). The same helper EmoteKit's suites use.
///
/// ⚠️ LOOKS, NOT A WALL-CLOCK DEADLINE. A sign-up step hops through actors and
/// the main actor; on a loaded CI runner a fixed 200 ms was not enough for
/// `aCodeForAnExistingAccountSignsInWithoutMoreSteps` (#650's run
/// 37679063039: the account never became the session in the window). A frozen
/// process now costs no budget, and the flow gets every turn the wait gives up.
///
/// The waits that matter are `#require`d: one that gives up silently makes
/// the next step a no-op.
@MainActor
@discardableResult
func settle(looks: Int = 2_000, until condition: () async -> Bool) async -> Bool {
    for _ in 0..<looks {
        await Task.yield()
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
