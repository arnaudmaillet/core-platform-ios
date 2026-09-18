import Testing
@testable import Upload

/// The arithmetic the header's two arrows walk, without a screen.
///
/// ⚠️ **THE RULES ARE HERE, NOT IN THE EDITOR'S TESTS.** Every one of these can
/// be broken in a way that only shows after three or four gestures in a row —
/// the future that survives a new change, the oldest step falling off the end —
/// and a test that has to drive a view controller to reach the fourth gesture
/// would be pinning the gesture, not the rule.
struct MediaEditHistoryTests {
    private func history() -> MediaEditHistory<String> { MediaEditHistory<String>() }

    @Test func aStepIsWhatThePageWasWearingBefore() {
        var past = history()
        past.record("a", changingTo: "b", for: "one")

        #expect(past.canUndo("one"))
        #expect(past.undo("one", from: "b") == "a")
    }

    /// ⚠️ **A CHANGE THAT CHANGED NOTHING IS NOT A STEP.** Choosing the look a
    /// page already wears, or a drag that ends where it began, would otherwise
    /// light the arrow over a step that undoes to itself.
    @Test func aChangeThatChangedNothingIsNotAStep() {
        var past = history()
        past.record("a", changingTo: "a", for: "one")

        #expect(!past.canUndo("one"))
        #expect(past.undo("one", from: "a") == nil)
    }

    @Test func whatIsSteppedBackFromCanBeSteppedForwardInto() {
        var past = history()
        past.record("a", changingTo: "b", for: "one")

        #expect(past.undo("one", from: "b") == "a")
        #expect(past.canRedo("one"))
        #expect(past.redo("one", from: "a") == "b")
        #expect(!past.canRedo("one"), "the way forward was taken")
        #expect(past.canUndo("one"), "and the way back came back")
    }

    /// ⚠️ **A NEW CHANGE ENDS THE FUTURE.** What was undone and then built on
    /// top of is not reachable any more; offering it would hand the author a
    /// page they never made — "b with c on top" is not a state that ever was.
    @Test func aNewChangeEndsTheWayForward() {
        var past = history()
        past.record("a", changingTo: "b", for: "one")
        _ = past.undo("one", from: "b")
        #expect(past.canRedo("one"), "guard")

        past.record("a", changingTo: "c", for: "one")

        #expect(!past.canRedo("one"))
        #expect(past.undo("one", from: "c") == "a", "and the way back is still the real one")
    }

    /// ⚠️ **THE OLDEST GOES, NOT THE NEWEST.** Dropping the newest would make
    /// the arrow undo a change the author made two gestures ago and leave the
    /// last one on the page for good.
    @Test func theOldestStepFallsOffTheEnd() {
        var past = history()
        let depth = MediaEditHistory<String>.depth
        for step in 0...depth { past.record("step-\(step)", changingTo: "step-\(step + 1)", for: "one") }

        #expect(past.debugDepths("one").back == depth, "got \(past.debugDepths("one"))")
        var state = "step-\(depth + 1)"
        for _ in 0..<depth { state = past.undo("one", from: state) ?? state }

        #expect(state == "step-1", "walking all the way back reached \(state)")
        #expect(!past.canUndo("one"))
    }

    /// ⚠️ **PER PAGE.** The arrows act on the picture in front of the author;
    /// one shared list would have a step taken on page two undo something on
    /// page one that they cannot even see.
    @Test func eachPageWalksItsOwn() {
        var past = history()
        past.record("a", changingTo: "b", for: "one")

        #expect(!past.canUndo("two"))
        #expect(past.undo("two", from: "z") == nil)
        #expect(past.canUndo("one"), "and page one kept its own")
    }

    @Test func aPageCanBeLetGoOfAndTheEditorCanLetGoOfEverything() {
        var past = history()
        past.record("a", changingTo: "b", for: "one")
        past.record("a", changingTo: "b", for: "two")
        _ = past.undo("two", from: "b")

        past.forget("two")
        #expect(!past.canUndo("two") && !past.canRedo("two"))
        #expect(past.canUndo("one"), "guard: only the page asked for")

        past.forgetEverything()
        #expect(!past.canUndo("one"))
    }
}
