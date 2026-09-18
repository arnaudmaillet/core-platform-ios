/// What the editor's back and forward arrows walk.
///
/// ⚠️ **PURE, AND A VALUE — SO A STEP CAN BE ASKED ABOUT WITHOUT A SCREEN.**
/// Undo and redo are decided by a rule ("what was the page wearing before this
/// change?"), and a rule inside a view controller can only be checked by
/// driving a view controller.
///
/// ⚠️ **A STEP IS ONE SETTLED CHANGE, AND A DRAG IS ONE STEP.** The author's
/// finger writes sixty values a second on a ruler; sixty steps would make the
/// back arrow useless, and a history that recorded only the last would lose the
/// look they started from. The editor decides what "settled" means (it knows
/// whether a finger is down) and only settled changes reach `record`.
///
/// ⚠️ **PER PAGE.** Asked for that way, and it is also the only reading that
/// makes sense on a phone: the arrows act on the picture in front of the
/// author, never on one they would have to swipe back to in order to see what
/// happened.
struct MediaEditHistory<State: Equatable>: Equatable {
    /// How many steps back one page may hold.
    ///
    /// ⚠️ **A CEILING, BECAUSE A STATE IS NOT FREE.** `MediaEdits` carries
    /// every overlay, every piece of the timeline and every look; twenty of
    /// them per page is a depth no author reaches by hand and a size nobody
    /// notices.
    static var depth: Int { 20 }

    private var past: [String: [State]] = [:]
    private var future: [String: [State]] = [:]

    init() {}

    /// Files what `id` was wearing BEFORE the change that is being made.
    ///
    /// ⚠️ **THE STATE BEFORE, NOT THE ONE AFTER.** Undo has to hand back
    /// something; a history of what the page became would always be one step
    /// short of the first thing the author did.
    ///
    /// ⚠️ **AND A CHANGE THAT CHANGED NOTHING IS NOT A STEP.** Choosing the
    /// look a page already wears, or a drag that ends where it began, would
    /// otherwise fill the history with steps that undo to themselves — the back
    /// arrow lit, and pressing it doing nothing visible.
    mutating func record(_ before: State, changingTo after: State, for id: String) {
        guard before != after else { return }
        var steps = past[id] ?? []
        steps.append(before)
        if steps.count > Self.depth { steps.removeFirst(steps.count - Self.depth) }
        past[id] = steps
        // ⚠️ **A NEW CHANGE ENDS THE FUTURE.** Anything that was undone and then
        // built on top of is not reachable any more, and offering to redo into
        // it would hand the author a page they never made.
        future[id] = nil
    }

    func canUndo(_ id: String) -> Bool { !(past[id] ?? []).isEmpty }
    func canRedo(_ id: String) -> Bool { !(future[id] ?? []).isEmpty }

    /// The state to go back to, with `current` filed for the forward arrow.
    mutating func undo(_ id: String, from current: State) -> State? {
        guard var steps = past[id], let previous = steps.popLast() else { return nil }
        past[id] = steps
        var ahead = future[id] ?? []
        ahead.append(current)
        future[id] = ahead
        return previous
    }

    /// The state to go forward to, with `current` filed for the back arrow.
    mutating func redo(_ id: String, from current: State) -> State? {
        guard var ahead = future[id], let next = ahead.popLast() else { return nil }
        future[id] = ahead
        var steps = past[id] ?? []
        steps.append(current)
        past[id] = steps
        return next
    }

    /// Lets a page's history go — the editor closing, or the page leaving the
    /// selection.
    mutating func forget(_ id: String) {
        past[id] = nil
        future[id] = nil
    }

    mutating func forgetEverything() {
        past = [:]
        future = [:]
    }

    /// Internal for tests: how deep each side stands.
    func debugDepths(_ id: String) -> (back: Int, forward: Int) {
        ((past[id] ?? []).count, (future[id] ?? []).count)
    }
}
